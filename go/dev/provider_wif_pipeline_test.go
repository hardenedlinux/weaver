// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const wifFanout = 4

type wifPeer struct {
	operations          int
	initialTTL          int
	assertion           string
	exchanges, messages atomic.Int64
	unauthorized        atomic.Bool
	refreshStarted      chan struct{}
	releaseRefresh      chan struct{}
	mu                  sync.Mutex
	lastAssertion       string
	tokenExpiry         map[string]time.Time
}

func (p *wifPeer) start(t testing.TB, dir string, cert tls.Certificate) []string {
	t.Helper()
	p.assertion = filepath.Join(dir, "snake-oil.jwt")
	p.rotate(t, "initial")
	p.tokenExpiry = make(map[string]time.Time)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Host != "api.anthropic.com" ||
			r.TLS == nil || r.TLS.ServerName != "api.anthropic.com" || r.URL.RawQuery != "" {
			t.Error("WIF peer received an unbound request")
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		switch r.URL.Path {
		case "/v1/oauth/token":
			var request struct {
				Grant        string `json:"grant_type"`
				Assertion    string `json:"assertion"`
				Rule         string `json:"federation_rule_id"`
				Organization string `json:"organization_id"`
				Account      string `json:"service_account_id"`
				Workspace    string `json:"workspace_id"`
			}
			n := p.exchanges.Add(1)
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&request); err != nil ||
				request.Grant != "urn:ietf:params:oauth:grant-type:jwt-bearer" ||
				request.Rule != "fdrl_snake-oil" || request.Organization != "00000000-0000-0000-0000-000000000000" ||
				request.Account != "svac_snake-oil" || request.Workspace != "wrkspc_snake-oil" ||
				(request.Assertion != "synthetic.initial.jwt" && request.Assertion != "synthetic.rotated.jwt" && request.Assertion != "synthetic.expiring.jwt") {
				t.Error("invalid synthetic exchange request")
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if n == 2 && p.refreshStarted != nil {
				close(p.refreshStarted)
				select {
				case <-p.releaseRefresh:
				case <-r.Context().Done():
					return
				}
			}
			ttl := 60
			if n == 1 {
				ttl = p.initialTTL
			}
			if request.Assertion == "synthetic.expiring.jwt" {
				ttl = 1
			}
			token := fmt.Sprintf("sk-ant-oat01-snake-oil-%d", n)
			p.mu.Lock()
			p.lastAssertion = request.Assertion
			p.tokenExpiry["Bearer "+token] = time.Now().Add(time.Duration(ttl) * time.Second)
			p.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"access_token":%q,"token_type":"Bearer","expires_in":%d,"scope":"workspace:inference"}`, token, ttl)
		case "/v1/messages":
			p.messages.Add(1)
			p.mu.Lock()
			expiry := p.tokenExpiry[r.Header.Get("Authorization")]
			p.mu.Unlock()
			if !time.Now().Before(expiry) || r.Header.Get("X-Api-Key") != "" || r.Header.Get("Anthropic-Version") != "2023-06-01" {
				t.Error("inference did not use a current bearer from the synthetic exchange")
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			var request struct {
				Model     string `json:"model"`
				Stream    bool   `json:"stream"`
				MaxTokens int    `json:"max_tokens"`
			}
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&request); err != nil ||
				request.Model != "model-a" || !request.Stream || request.MaxTokens != 32 {
				t.Error("unexpected inference request")
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			if p.unauthorized.Load() {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Type", "text/event-stream")
			emitAnthropic(w, true)
		default:
			t.Error("unexpected provider path")
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}
	server.StartTLS()
	t.Cleanup(server.Close)
	config, err := json.Marshal(map[string]any{"primary": map[string]string{
		"assertion_file": p.assertion, "federation_rule_id": "fdrl_snake-oil",
		"organization_id":    "00000000-0000-0000-0000-000000000000",
		"service_account_id": "svac_snake-oil", "workspace_id": "wrkspc_snake-oil",
	}})
	if err != nil {
		t.Fatal(err)
	}
	return []string{
		"WEAVER_PROVIDER_CREDENTIAL_ENVS={}", "WEAVER_ANTHROPIC_WIF=" + string(config),
		"WEAVER_TEST_WIF_PEER=" + server.Listener.Addr().String(), "WEAVER_STORAGE_JOURNAL=mvcc",
	}
}

func (p *wifPeer) rotate(t testing.TB, generation string) {
	t.Helper()
	next := p.assertion + ".next"
	if err := os.WriteFile(next, []byte("synthetic."+generation+".jwt"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(next, p.assertion); err != nil {
		t.Fatal(err)
	}
}

func wifImage(t testing.TB, optimized bool) string {
	t.Helper()
	args := []string{"test", "-p", "weaver-server", "--lib", "--features", "arrow", "--locked", "--offline", "--no-run", "--message-format=json"}
	if optimized {
		args = append(args, "--release")
	}
	cmd := exec.Command("cargo", args...)
	cmd.Dir = root(t)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	binary, err := buildCargoExecutable(cmd, cargoTarget{Name: "weaver_server", Kind: "lib", Test: true, Optimized: optimized})
	if err != nil {
		t.Fatalf("WIF test image: %v: %s", err, stderr.String())
	}
	image := filepath.Join(t.TempDir(), "weaver-wif")
	digest, err := publishProviderImage(binary, image)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("WIF test image sha256=%s optimized=%t", digest, optimized)
	return image
}

func wifFixture(t testing.TB, image string, p *wifPeer) *fixture {
	t.Helper()
	profile := providerProfile()
	profile.Protocol = v1.AnthropicMessagesSSE
	return providerFixture(t, nil, false, image,
		[]string{"--exact", "grpc_config::serve_wif_gateway", "--ignored", "--nocapture"},
		nil, profile, p)
}

type wifResult struct {
	receipt         *pb.ProviderReceipt
	err             error
	first, terminal time.Duration
	text            string
}

func invokeWif(ctx context.Context, f *fixture, plan v1.ProviderPlan) wifResult {
	started := time.Now()
	var result wifResult
	result.receipt, result.err = f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(event *pb.Event) error {
		if result.first == 0 {
			result.first = time.Since(started)
		}
		result.text += event.Text
		return nil
	})
	result.terminal = time.Since(started)
	return result
}

func requireWifCompletion(t testing.TB, result wifResult) {
	t.Helper()
	if result.err != nil || result.first <= 0 || result.text != "hello" ||
		result.receipt.GetReserved() != 4 || result.receipt.GetHeld() < 4 || result.receipt.GetTarget() != "primary" {
		t.Fatalf("unexpected completed inference: %+v", result)
	}
}

func wifWave(ctx context.Context, f *fixture, plans []v1.ProviderPlan) <-chan wifResult {
	result := make(chan wifResult, len(plans))
	start := make(chan struct{})
	var ready sync.WaitGroup
	ready.Add(len(plans))
	for _, plan := range plans {
		go func() {
			ready.Done()
			<-start
			result <- invokeWif(ctx, f, plan)
		}()
	}
	ready.Wait()
	close(start)
	return result
}

func requireWifUnknown(t testing.TB, ctx context.Context, f *fixture, plan v1.ProviderPlan, held uint64) {
	t.Helper()
	r, err := f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: plan.Family, Node: plan.Node})
	if err != nil || r.GetState() != "unknown" || r.GetHeld() != held || r.GetReserved() != 4 {
		t.Fatalf("original reservation did not remain unknown: %v %v", r, err)
	}
}

func TestAnthropicWifSnakeOilPipeline(t *testing.T) {
	peer := &wifPeer{operations: wifFanout + 5, initialTTL: 11, refreshStarted: make(chan struct{}), releaseRefresh: make(chan struct{})}
	var release sync.Once
	unblock := func() { release.Do(func() { close(peer.releaseRefresh) }) }
	defer unblock()
	f := wifFixture(t, wifImage(t, false), peer)
	ctx, cancel := context.WithTimeout(t.Context(), 35*time.Second)
	defer cancel()
	requireWifCompletion(t, invokeWif(ctx, f, f.plans[0]))
	peer.mu.Lock()
	expiry := peer.tokenExpiry["Bearer sk-ant-oat01-snake-oil-1"]
	peer.mu.Unlock()
	timer := time.NewTimer(time.Until(expiry))
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	peer.rotate(t, "rotated")
	plans := f.plans[1 : wifFanout+1]
	result := wifWave(ctx, f, plans)
	select {
	case <-peer.refreshStarted:
	case early := <-result:
		t.Fatalf("operation returned before the refresh cut: %+v", early)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	// The exchange can wait outside the guarded write while all claims commit.
	cutCtx, cancelCut := context.WithTimeout(ctx, 4*time.Second)
	defer cancelCut()
	for _, plan := range plans {
		for {
			r, err := f.client.RPC.Inspect(f.client.Context(cutCtx), &pb.OperationKey{Family: plan.Family, Node: plan.Node})
			if err == nil && r.GetState() == "unknown" && r.GetReserved() == 4 && r.GetHeld() == 4*(wifFanout+1) {
				break
			}
			select {
			case <-time.After(5 * time.Millisecond):
			case early := <-result:
				t.Fatalf("operation returned while exchange was paused: %+v", early)
			case <-cutCtx.Done():
				t.Fatalf("claim %s did not commit while exchange was paused: %v", plan.Node, cutCtx.Err())
			}
		}
	}
	if peer.messages.Load() != 1 || peer.exchanges.Load() != 2 {
		t.Fatal("unrefreshed wave reached the writer")
	}
	unblock()
	for range plans {
		requireWifCompletion(t, <-result)
	}
	peer.mu.Lock()
	rotated := peer.lastAssertion
	peer.mu.Unlock()
	if rotated != "synthetic.rotated.jwt" || peer.exchanges.Load() != 2 || peer.messages.Load() != wifFanout+1 {
		t.Fatal("concurrent refresh did not use the rotated assertion exactly once")
	}
	requireWifCompletion(t, invokeWif(ctx, f, f.plans[wifFanout+1]))
	peer.unauthorized.Store(true)
	rejected := f.plans[wifFanout+2]
	if result := invokeWif(ctx, f, rejected); status.Code(result.err) != codes.FailedPrecondition {
		t.Fatalf("inference 401: %v", result.err)
	}
	requireWifUnknown(t, ctx, f, rejected, 4*(wifFanout+3))
	if peer.messages.Load() != wifFanout+3 || peer.exchanges.Load() != 2 {
		t.Fatal("warm or unauthorized call retried or exchanged again")
	}
	f.stop(t)
	f.start(t)
	if replay := invokeWif(ctx, f, rejected); status.Code(replay.err) != codes.FailedPrecondition {
		t.Fatalf("401 recovery replay: %v", replay.err)
	}
	requireWifUnknown(t, ctx, f, rejected, 4*(wifFanout+3))
	if peer.messages.Load() != wifFanout+3 || peer.exchanges.Load() != 2 {
		t.Fatal("restart reopened an unauthorized inference")
	}

	peer.rotate(t, "expiring")
	expiring := f.plans[wifFanout+3]
	if result := invokeWif(ctx, f, expiring); status.Code(result.err) != codes.FailedPrecondition {
		t.Fatalf("near-expiry exchange: %v", result.err)
	}
	requireWifUnknown(t, ctx, f, expiring, 4*(wifFanout+4))
	f.stop(t)
	f.start(t)
	if replay := invokeWif(ctx, f, expiring); status.Code(replay.err) != codes.FailedPrecondition {
		t.Fatalf("expiry recovery replay: %v", replay.err)
	}
	requireWifUnknown(t, ctx, f, expiring, 4*(wifFanout+4))
	if peer.messages.Load() != wifFanout+3 || peer.exchanges.Load() != 3 {
		t.Fatal("near-expiry credential or restart reached inference")
	}

	peer.unauthorized.Store(false)
	peer.rotate(t, "rotated")
	requireWifCompletion(t, invokeWif(ctx, f, f.plans[wifFanout+4]))
	for _, original := range []v1.ProviderPlan{rejected, expiring} {
		if replay := invokeWif(ctx, f, original); status.Code(replay.err) != codes.FailedPrecondition {
			t.Fatalf("a fresh credential reopened %s: %v", original.Node, replay.err)
		}
		requireWifUnknown(t, ctx, f, original, 4*(wifFanout+5))
	}
	if peer.messages.Load() != wifFanout+4 || peer.exchanges.Load() != 4 {
		t.Fatal("a fresh credential changed the original dispatch count")
	}
}

func BenchmarkAnthropicWifSnakeOilPair(b *testing.B) {
	image := wifImage(b, true)
	modes := [...]string{"cold", "refresh", "warm"}
	type times struct{ first, terminal, wave time.Duration }
	var totals [len(modes)]times
	b.StopTimer()
	for round := range b.N {
		for arm := range modes {
			mode := (round + arm) % len(modes)
			peer := &wifPeer{operations: wifFanout + 1, initialTTL: 60}
			if mode == 1 {
				peer.initialTTL = 11
			}
			f := wifFixture(b, image, peer)
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			requireWifCompletion(b, invokeWif(ctx, f, f.plans[0]))
			if mode == 0 {
				f.stop(b)
				f.start(b)
			}
			plans := f.plans[1:]
			if mode == 1 {
				peer.rotate(b, "rotated")
			}
			beforeExchange, beforeMessages := peer.exchanges.Load(), peer.messages.Load()
			b.StartTimer()
			started := time.Now()
			out := wifWave(ctx, f, plans)
			for range plans {
				result := <-out
				requireWifCompletion(b, result)
				totals[mode].first += result.first
				totals[mode].terminal += result.terminal
			}
			totals[mode].wave += time.Since(started)
			b.StopTimer()
			wantExchange := int64(1)
			if mode == 2 {
				wantExchange = 0
			}
			if peer.exchanges.Load()-beforeExchange != wantExchange ||
				peer.messages.Load()-beforeMessages != int64(len(plans)) {
				b.Fatal("benchmark phase had unexpected exchange or inference counts")
			}
			cancel()
			f.stop(b)
		}
	}
	b.ReportMetric(0, "ns/op")
	for i, mode := range modes {
		count := b.N * wifFanout
		b.ReportMetric(float64(totals[i].first.Nanoseconds())/float64(count), mode+"-first-ns/stream")
		b.ReportMetric(float64(totals[i].terminal.Nanoseconds())/float64(count), mode+"-terminal-ns/stream")
		b.ReportMetric(float64(totals[i].wave.Nanoseconds())/float64(b.N), mode+"-ns/wave")
	}
}
