// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc/metadata"
)

const relayRoot = "synthetic-oauth-ingress-root-token"
const relayLeaf = "synthetic-oauth-downstream-leaf-token"

func oauthDigest(data []byte) string {
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

type oauthRelayFixture struct {
	rust          *fixture
	goServer      *controlProcess
	plans         []v1.ProviderPlan
	key           ed25519.PrivateKey
	peer, relay   string
	issued, epoch uint64
}

func newOAuthRelayFixture(t testing.TB, handler http.HandlerFunc, enabled bool, observedImage ...string) *oauthRelayFixture {
	t.Helper()
	first, second := pki(t), pki(t)
	public, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pair := &oauthRelayFixture{key: key, issued: uint64(time.Now().Unix()), peer: oauthDigest(first.client.Certificate[0]), relay: oauthDigest(second.client.Certificate[0])}
	env := []string{"WEAVER_STORAGE_JOURNAL=mvcc"}
	if enabled {
		witness := filepath.Join(t.TempDir(), "authority.log")
		if err := os.WriteFile(witness, nil, 0600); err != nil {
			t.Fatal(err)
		}
		config, err := json.Marshal(map[string]string{
			"witness_file": witness,
			"issuer":       "issuer", "subject": "alice", "client": "gateway-client", "audience": "weaver",
			"public_key": hex.EncodeToString(public), "relay_certificate_sha256": pair.relay,
		})
		if err != nil {
			t.Fatal(err)
		}
		env = append(env, "WEAVER_PROVIDER_OAUTH="+string(config))
	}
	image := serverBinary
	var args []string
	if len(observedImage) != 0 {
		image = observedImage[0]
		args = []string{"--exact", "grpc_config::serve_wif_gateway", "--ignored", "--nocapture"}
		env = append(env, "WEAVER_TEST_PROVIDER_TIMINGS=1")
	}
	pair.rust = providerFixture(t, handler, false, image, args, env, providerProfile(), nil, second)
	bundle := controlBundle(t, pair.rust)
	pair.plans = bundle.Plans
	pair.goServer = newControlProcess(t, pair.rust, writeControlBundle(t, pair.rust, bundle, "json"))
	pair.goServer.ingress = first
	ingressCA := filepath.Join(pair.goServer.directory, "ingress-ca.pem")
	if err := os.WriteFile(ingressCA, first.ca, 0600); err != nil {
		t.Fatal(err)
	}
	pair.goServer.env = append(pair.goServer.env, "WEAVER_CONTROL_CLIENT_CA="+ingressCA, "WEAVER_CONTROL_PEER_SHA256="+pair.peer)
	if enabled {
		pair.goServer.env = append(pair.goServer.env, "WEAVER_CONTROL_PROVIDER_OAUTH_RELAY=1")
	}
	pair.goServer.start(t)
	return pair
}

func (p *oauthRelayFixture) grant(t testing.TB, token, cert, parent string, scopes ...string) *pb.ProviderOAuthChange {
	t.Helper()
	now := p.issued
	g := &pb.ProviderOAuthGrant{
		Issuer: "issuer", Subject: "alice", Client: "gateway-client", Audience: "weaver",
		Scopes: scopes, TokenHash: oauthDigest([]byte(token)), CertificateSha256: cert,
		NotBefore: now - 60, ExpiresAt: now + 600, ParentTokenHash: parent, IssuerEpoch: p.epoch,
	}
	fields := []any{"weaver.provider-oauth.grant.v1", g.Issuer, g.Subject, g.Client, g.Audience, g.Scopes,
		g.TokenHash, g.CertificateSha256, g.NotBefore, g.ExpiresAt}
	if p.epoch != 0 {
		fields[0] = "weaver.provider-oauth.epoch-grant.v1"
		var lineage any
		if parent != "" {
			lineage = parent
		}
		fields = append(fields, lineage, p.epoch)
	} else if parent != "" {
		fields[0] = "weaver.provider-oauth.delegated-grant.v1"
		fields = append(fields, parent)
	}
	data, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	g.Signature = hex.EncodeToString(ed25519.Sign(p.key, digest[:]))
	return &pb.ProviderOAuthChange{Action: &pb.ProviderOAuthChange_Grant{Grant: g}}
}

func (p *oauthRelayFixture) change(ctx context.Context, change *pb.ProviderOAuthChange) error {
	_, err := p.rust.admin.RPC.ChangeProviderOAuth(p.rust.admin.Context(ctx), change)
	return err
}

func (p *oauthRelayFixture) publish(t testing.TB, ctx context.Context, change *pb.ProviderOAuthChange) {
	t.Helper()
	if err := p.change(ctx, change); err != nil {
		t.Fatal(err)
	}
}

func (p *oauthRelayFixture) tokens(t testing.TB, ctx context.Context) {
	t.Helper()
	root := p.grant(t, relayRoot, p.peer, "", "provider:execute", "provider:inspect")
	p.publish(t, ctx, root)
	p.publish(t, ctx, p.grant(t, relayLeaf, p.relay, root.GetGrant().TokenHash, "provider:execute", "provider:inspect"))
}

func TestProviderOAuthTwoHopRevocationAndRecovery(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	defer unblock()
	var attempts int
	var lock sync.Mutex
	p := newOAuthRelayFixture(t, func(w http.ResponseWriter, r *http.Request) {
		lock.Lock()
		attempts++
		second := attempts == 2
		lock.Unlock()
		if second {
			close(entered)
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
		}
		completeSSE(w, r)
	}, true)
	ctx, cancel := context.WithTimeout(t.Context(), 18*time.Second)
	defer cancel()
	p.tokens(t, ctx)
	wrong := p.grant(t, "synthetic-oauth-wrong-ingress-root-token", oauthDigest([]byte("wrong")), "", "provider:execute", "provider:inspect")
	p.publish(t, ctx, wrong)
	const wrongLeaf = "synthetic-oauth-wrong-ingress-leaf-token"
	p.publish(t, ctx, p.grant(t, wrongLeaf, p.relay, wrong.GetGrant().TokenHash, "provider:execute"))
	call := func(ctx context.Context, node int, token string, receive func(*pb.Event) error) (*pb.ProviderReceipt, error) {
		return p.goServer.client.Execute(gatewayclient.WithProviderOAuth(ctx, token), p.plans[node], pb.Encoding_PROTOBUF, 1, receive)
	}
	ignore := func(*pb.Event) error { return nil }
	if _, err := call(ctx, 0, wrongLeaf, ignore); err == nil {
		t.Fatal("wrong ingress peer accepted")
	}
	spoofed := metadata.AppendToOutgoingContext(ctx, "weaver-provider-oauth-ingress-cert", p.peer)
	if _, err := call(spoofed, 0, relayLeaf, ignore); err == nil {
		t.Fatal("caller supplied ingress assertion")
	}
	if _, err := p.rust.client.Execute(gatewayclient.WithProviderOAuth(ctx, relayLeaf), p.plans[0], pb.Encoding_PROTOBUF, 1, ignore); err == nil {
		t.Fatal("relay grant accepted without first-hop evidence")
	}
	if p.rust.primary.Load() != 0 {
		t.Fatal("rejected request reached the provider")
	}
	if got, err := call(ctx, 0, relayLeaf, ignore); err != nil || got.GetState() != "complete" {
		t.Fatalf("successful dual-hop receipt: %v %v", got, err)
	}
	job := make(chan error, 1)
	go func() {
		_, err := call(ctx, 1, relayLeaf, func(*pb.Event) error { t.Error("revoked frame released"); return nil })
		job <- err
	}()
	select {
	case <-entered:
	case err := <-job:
		t.Fatalf("provider did not start: %v", err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	rootHash := oauthDigest([]byte(relayRoot))
	p.publish(t, ctx, &pb.ProviderOAuthChange{Action: &pb.ProviderOAuthChange_RevokeTokenHash{RevokeTokenHash: rootHash}})
	unblock()
	if err := <-job; err == nil {
		t.Fatal("parent revocation did not prevent release")
	}
	p.goServer.stop(t)
	p.rust.stop(t)
	p.rust.start(t)
	p.goServer.start(t)
	if err := p.change(ctx, p.grant(t, "synthetic-oauth-late-child-token", p.relay, rootHash, "provider:execute")); err == nil {
		t.Fatal("late child of revoked root accepted")
	}
	if _, err := call(ctx, 1, relayLeaf, ignore); err == nil {
		t.Fatal("restart reopened revoked effect")
	}
	const observerRoot = "synthetic-oauth-inspector-root-token"
	const observerLeaf = "synthetic-oauth-inspector-leaf-token"
	observer := p.grant(t, observerRoot, p.peer, "", "provider:inspect")
	p.publish(t, ctx, observer)
	p.publish(t, ctx, p.grant(t, observerLeaf, p.relay, observer.GetGrant().TokenHash, "provider:inspect"))
	receipt, err := p.goServer.client.RPC.Inspect(p.goServer.client.Context(gatewayclient.WithProviderOAuth(ctx, observerLeaf)), &pb.OperationKey{Family: p.plans[1].Family, Node: p.plans[1].Node})
	if err != nil || receipt.GetState() != "unknown" || receipt.GetReserved() != 4 || receipt.GetHeld() != 8 || receipt.GetEvents() != 0 || p.rust.primary.Load() != 2 {
		t.Fatalf("original effect or hold changed: receipt=%v requests=%d error=%v", receipt, p.rust.primary.Load(), err)
	}
}

func (p *oauthRelayFixture) rotate(t testing.TB, ctx context.Context) *pb.ProviderOAuthChange {
	t.Helper()
	public, next, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	current := hex.EncodeToString(p.key.Public().(ed25519.PublicKey))
	key := hex.EncodeToString(public)
	data, err := json.Marshal([]any{"weaver.provider-oauth.rotate-issuer.v1", "issuer", current, p.epoch, key})
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	change := &pb.ProviderOAuthChange{Action: &pb.ProviderOAuthChange_RotateIssuer{
		RotateIssuer: &pb.ProviderOAuthIssuerRotation{
			ExpectedEpoch: p.epoch, PublicKey: key,
			Signature: hex.EncodeToString(ed25519.Sign(p.key, digest[:])),
		},
	}}
	p.publish(t, ctx, change)
	p.key, p.epoch = next, p.epoch+1
	return change
}

func oauthDatabaseImage(t *testing.T, dir string) map[string][]byte {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	image := make(map[string][]byte)
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasPrefix(entry.Name(), "owner.db") {
			image[entry.Name()], err = os.ReadFile(filepath.Join(dir, entry.Name()))
			if err != nil {
				t.Fatal(err)
			}
		}
	}
	if len(image["owner.db"]) == 0 {
		t.Fatal("deciding database missing from snapshot")
	}
	return image
}

func TestProviderOAuthIndependentWitnessRejectsRollback(t *testing.T) {
	p := newOAuthRelayFixture(t, completeSSE, true)
	ctx, cancel := context.WithTimeout(t.Context(), 25*time.Second)
	defer cancel()
	p.tokens(t, ctx)
	p.goServer.stop(t)
	p.rust.stop(t)
	oldImage := oauthDatabaseImage(t, p.rust.directory)
	p.rust.start(t)
	p.goServer.start(t)
	stale := p.grant(t, "synthetic-old-issuer-late-root-token", p.peer, "", "provider:execute")
	revoke := &pb.ProviderOAuthChange{Action: &pb.ProviderOAuthChange_RevokeTokenHash{RevokeTokenHash: oauthDigest([]byte(relayRoot))}}
	p.publish(t, ctx, revoke)
	rotation := p.rotate(t, ctx)
	p.goServer.stop(t)
	p.rust.stop(t)
	for name := range oauthDatabaseImage(t, p.rust.directory) {
		if err := os.Remove(filepath.Join(p.rust.directory, name)); err != nil {
			t.Fatal(err)
		}
	}
	for name, bytes := range oldImage {
		if err := os.WriteFile(filepath.Join(p.rust.directory, name), bytes, 0600); err != nil {
			t.Fatal(err)
		}
	}
	p.rust.start(t)
	p.goServer.start(t)
	p.publish(t, ctx, revoke)
	p.publish(t, ctx, rotation)
	if err := p.change(ctx, stale); err == nil {
		t.Fatal("restored store accepted retired issuer")
	}
	execute := func(token string) (*pb.ProviderReceipt, error) {
		return p.goServer.client.Execute(gatewayclient.WithProviderOAuth(ctx, token), p.plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
	}
	if _, err := execute(relayLeaf); err == nil || p.rust.primary.Load() != 0 {
		t.Fatal("revoked descendant survived snapshot restore")
	}
	const root, leaf = "synthetic-current-issuer-root-token", "synthetic-current-issuer-leaf-token"
	next := p.grant(t, root, p.peer, "", "provider:execute", "provider:inspect")
	p.publish(t, ctx, next)
	p.publish(t, ctx, p.grant(t, leaf, p.relay, next.GetGrant().TokenHash, "provider:execute", "provider:inspect"))
	if r, err := execute(leaf); err != nil || r.GetState() != "complete" || p.rust.primary.Load() != 1 {
		t.Fatalf("current issuer unavailable after witness reconciliation: %v %v", r, err)
	}
}

// Each ABBA block uses the same optimized Rust image and Go control binary.
// Boot, source publication and credential provisioning are outside the sample.
func BenchmarkProviderOAuthRelayPair(b *testing.B) {
	image := wifImage(b, true)
	var totals [2][7]float64
	b.StopTimer()
	for range b.N {
		for _, arm := range []int{0, 1, 1, 0} {
			p := newOAuthRelayFixture(b, completeSSE, arm == 1, image)
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			if arm == 1 {
				p.tokens(b, ctx)
				ctx = gatewayclient.WithProviderOAuth(ctx, relayLeaf)
			}
			b.StartTimer()
			started := time.Now()
			var first time.Duration
			receipt, err := p.goServer.client.Execute(ctx, p.plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error {
				if first == 0 {
					first = time.Since(started)
				}
				return nil
			})
			terminal := time.Since(started)
			b.StopTimer()
			cancel()
			if err != nil || receipt.GetState() != "complete" || first == 0 || p.rust.primary.Load() != 1 {
				b.Fatalf("timed operation did not complete exactly once: %v %v", receipt, err)
			}
			log, err := os.ReadFile(filepath.Join(p.rust.directory, "server.log"))
			if err != nil {
				b.Fatal(err)
			}
			var times [5]uint64
			count := 0
			for _, line := range strings.Split(string(log), "\n") {
				if strings.HasPrefix(line, "weaver-oauth-timing ") {
					_, err = fmt.Sscanf(line, "weaver-oauth-timing %d %d %d %d %d", &times[0], &times[1], &times[2], &times[3], &times[4])
					if err != nil {
						b.Fatal(err)
					}
					count++
				}
			}
			if count != 1 || times[0] == 0 || times[1] == 0 {
				b.Fatalf("missing live transaction timings: %d %v", count, times)
			}
			totals[arm][0] += float64(first.Nanoseconds())
			totals[arm][1] += float64(terminal.Nanoseconds())
			for i, value := range times {
				totals[arm][2+i] += float64(value)
			}
			p.goServer.stop(b)
			p.rust.stop(b)
		}
	}
	b.ReportMetric(0, "ns/op")
	for arm, name := range []string{"baseline", "oauth"} {
		for i, label := range []string{"first", "terminal", "grant-check", "domain-hold", "txn-hold", "write", "queue"} {
			b.ReportMetric(totals[arm][i]/float64(2*b.N), name+"-"+label+"-ns/stream")
		}
	}
}
