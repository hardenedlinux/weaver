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
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
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
	pair, ingress := newOAuthRelayOwner(t, handler, enabled, observedImage, false, false)
	bundle := controlBundle(t, pair.rust)
	pair.plans = bundle.Plans
	pair.goServer = pair.startControl(t, ingress, bundle, enabled)
	return pair
}

func (p *oauthRelayFixture) startControl(t testing.TB, ingress *testPKI, bundle config.Bundle, enabled bool) *controlProcess {
	t.Helper()
	control := newControlProcess(t, p.rust, writeControlBundle(t, p.rust, bundle, "json"))
	control.ingress = ingress
	ingressCA := filepath.Join(control.directory, "ingress-ca.pem")
	if err := os.WriteFile(ingressCA, ingress.ca, 0600); err != nil {
		t.Fatal(err)
	}
	control.env = append(control.env, "WEAVER_CONTROL_CLIENT_CA="+ingressCA, "WEAVER_CONTROL_PEER_SHA256="+p.peer)
	if enabled {
		control.env = append(control.env, "WEAVER_CONTROL_PROVIDER_OAUTH_RELAY=1")
	}
	control.start(t)
	return control
}

func newOAuthRelayOwner(t testing.TB, handler http.HandlerFunc, enabled bool, observedImage []string, cachedPlans, lockedReview bool) (*oauthRelayFixture, *testPKI) {
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
		planMode := "0"
		if cachedPlans {
			planMode = "1"
		}
		reviewMode := "0"
		if lockedReview {
			reviewMode = "1"
		}
		env = append(env, "WEAVER_TEST_CACHE_CURRENTNESS_PLANS="+planMode, "WEAVER_TEST_LOCKED_PUBLICATION_REVIEW="+reviewMode)
	}
	pair.rust = providerFixture(t, handler, false, image, args, env, providerProfile(), nil, second)
	return pair, first
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
	var totals [2][len(providerTimingLabels) + 2]float64
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
			times := providerTimingTotals(b, p.rust, 1)
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
		for i, label := range append([]string{"first", "terminal"}, providerTimingLabels[:]...) {
			b.ReportMetric(totals[arm][i]/float64(2*b.N), name+"-"+label+"-ns/stream")
		}
	}
}

var providerTimingLabels = [...]string{"grant-check", "domain-hold", "txn-hold", "write", "queue", "grant-prepare", "txn-begin", "commit", "domain-wait", "domain-keys", "domain-read", "publication-read", "profile-read", "claim-read", "cedar", "rollback", "pending-read", "review-read", "birth-read", "publication-prepare"}

func providerTimingTotals(t testing.TB, f *fixture, want int) [len(providerTimingLabels)]uint64 {
	t.Helper()
	log, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	const prefix = "weaver-oauth-timing "
	var total [len(providerTimingLabels)]uint64
	count := 0
	for _, line := range strings.Split(string(log), "\n") {
		row, ok := strings.CutPrefix(line, prefix)
		if !ok {
			continue
		}
		fields := strings.Fields(row)
		if len(fields) != len(total) {
			t.Fatalf("unexpected timing field count: %d", len(fields))
		}
		for i, field := range fields {
			value, err := strconv.ParseUint(field, 10, 64)
			if err != nil {
				t.Fatal(err)
			}
			total[i] += value
		}
		count++
	}
	if count != want || total[0] == 0 || total[1] == 0 || total[10] == 0 || total[11] == 0 || total[12] == 0 || total[13] == 0 || total[14] == 0 {
		t.Fatalf("missing live MVCC timings: %d %v", count, total)
	}
	return total
}

func contentionRelayBundle(t testing.TB, f *fixture, family string) config.Bundle {
	t.Helper()
	bundle := controlBundle(t, f)
	plan := bundle.Plans[0]
	plan.Family = family
	bundle.Governance.Family = family
	bundle.Governance.OpenNodes = []string{plan.Node}
	bundle.Tasks = []v1.Task{profileTask(t, plan, *providerProfile())}
	bundle.Plans = []v1.ProviderPlan{plan}
	bundle.Publication.Policy = strings.Replace(bundle.Publication.Policy, `context.family == "control"`, `["left", "right"].contains(context.family)`, 1)
	if err := bundle.Validate(); err != nil {
		t.Fatal(err)
	}
	return bundle
}

type relayContentionSample struct {
	wall        time.Duration
	done, calls uint64
	timing      [len(providerTimingLabels)]uint64
}

func relayContentionWave(t *testing.B, image string, arm relayContentionArm) relayContentionSample {
	t.Helper()
	p, ingress := newOAuthRelayOwner(t, completeSSE, arm.oauth, []string{image}, arm.cachedPlans, arm.lockedReview)
	shared, oauth := arm.shared, arm.oauth
	left, right := contentionRelayBundle(t, p.rust, "left"), contentionRelayBundle(t, p.rust, "right")
	a, b := p.startControl(t, ingress, left, oauth), p.startControl(t, ingress, right, oauth)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if shared {
		merged, err := p.rust.admin.RPC.MigrateExecutionDomains(p.rust.admin.Context(ctx), &pb.DomainMigration{
			OperationId: "bench-share-domains", BudgetFrom: "left", BudgetTo: "right", HistoryFrom: "left", HistoryTo: "right",
			BudgetFromEpoch: 1, BudgetToEpoch: 1, HistoryFromEpoch: 1, HistoryToEpoch: 1,
		})
		if err != nil || !merged.GetCommitted() {
			t.Fatalf("shared authority domains were not installed: %v %v", merged, err)
		}
	}
	if oauth {
		p.tokens(t, ctx)
		ctx = gatewayclient.WithProviderOAuth(ctx, relayLeaf)
	}
	type result struct {
		receipt *pb.ProviderReceipt
		events  int
		err     error
	}
	results := make(chan result, 2)
	ready, start := make(chan struct{}, 2), make(chan struct{})
	for _, operation := range []struct {
		client *gatewayclient.Client
		plan   v1.ProviderPlan
	}{{a.client, left.Plans[0]}, {b.client, right.Plans[0]}} {
		go func() {
			ready <- struct{}{}
			<-start
			var r result
			r.receipt, r.err = operation.client.Execute(ctx, operation.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error {
				r.events++
				return nil
			})
			results <- r
		}()
	}
	<-ready
	<-ready
	t.StartTimer()
	started := time.Now()
	close(start)
	first, second := <-results, <-results
	wall := time.Since(started)
	t.StopTimer()
	sample := relayContentionSample{wall: wall, calls: uint64(p.rust.primary.Load())}
	for _, r := range []result{first, second} {
		switch {
		case r.err == nil && r.receipt.GetState() == "complete" && r.events == 5:
			sample.done++
		case status.Code(r.err) == codes.FailedPrecondition:
			if shared {
				t.Fatalf("shared-domain operation failed: %v", r.err)
			}
		default:
			t.Fatalf("invalid contention result: %+v", r)
		}
	}
	if sample.done == 0 || sample.calls < sample.done || sample.calls > 2 || p.rust.backup.Load() != 0 {
		t.Fatalf("invalid completion or provider counts: %+v", sample)
	}
	// Check real authoritative roots and retained exposure after the timed wave.
	var views [2]*pb.DomainView
	for i, family := range []string{"left", "right"} {
		view, err := p.rust.admin.RPC.InspectExecutionDomains(p.rust.admin.Context(ctx), &pb.OperationKey{Family: family})
		if err != nil {
			t.Fatal(err)
		}
		views[i] = view
	}
	if views[0].GetStamp().GetOrigin() == views[1].GetStamp().GetOrigin() ||
		(views[0].GetStamp().GetBudgetRoot() == views[1].GetStamp().GetBudgetRoot()) != shared ||
		(views[0].GetStamp().GetHistoryRoot() == views[1].GetStamp().GetHistoryRoot()) != shared {
		t.Fatal("authoritative domains differ from benchmark arm")
	}
	held := views[0].GetHeld()
	if !shared {
		held += views[1].GetHeld()
	}
	if held < 4*sample.calls || held > 8 {
		t.Fatalf("provider attempts lost original holds: calls=%d held=%d", sample.calls, held)
	}
	sample.timing = providerTimingTotals(t, p.rust, 2)
	a.stop(t)
	b.stop(t)
	p.rust.stop(t)
	return sample
}

// Each arm launches two canonical originals through two identical relay processes.
// Shared mode joins budget/history before measurement; cross mode leaves them independent.
type relayContentionArm struct {
	name                                     string
	shared, oauth, cachedPlans, lockedReview bool
}

func BenchmarkProviderOAuthDomainContention(b *testing.B) {
	benchmarkRelayContention(b, [4]relayContentionArm{
		{name: "shared-base", shared: true}, {name: "shared-oauth", shared: true, oauth: true},
		{name: "cross-base"}, {name: "cross-oauth", oauth: true},
	})
}

// Each pair changes only the native statement planning mode, with OAuth on.
func BenchmarkProviderCurrentnessPlans(b *testing.B) {
	benchmarkRelayContention(b, [4]relayContentionArm{
		{name: "shared-fresh", shared: true, oauth: true},
		{name: "shared-cached", shared: true, oauth: true, cachedPlans: true},
		{name: "cross-fresh", oauth: true}, {name: "cross-cached", oauth: true, cachedPlans: true},
	})
}

// Compare the previous locked review and the exact prepared match on one image.
func BenchmarkProviderPublicationReviewPair(b *testing.B) {
	benchmarkRelayContention(b, [4]relayContentionArm{
		{name: "shared-locked", shared: true, oauth: true, lockedReview: true},
		{name: "shared-prepared", shared: true, oauth: true},
		{name: "cross-locked", oauth: true, lockedReview: true},
		{name: "cross-prepared", oauth: true},
	})
}

func benchmarkRelayContention(b *testing.B, arms [4]relayContentionArm) {
	b.Helper()
	image := wifImage(b, true)
	b.StopTimer()
	var totals [4]relayContentionSample
	for range b.N {
		for _, arm := range []int{0, 1, 2, 3, 3, 2, 1, 0} {
			sample := relayContentionWave(b, image, arms[arm])
			total := &totals[arm]
			total.wall += sample.wall
			total.done += sample.done
			total.calls += sample.calls
			for i, value := range sample.timing {
				total.timing[i] += value
			}
		}
	}
	b.ReportMetric(0, "ns/op")
	for arm, settings := range arms {
		name := settings.name
		total := totals[arm]
		attempts := float64(4 * b.N)
		b.ReportMetric(float64(total.done)/total.wall.Seconds(), name+"-complete/s")
		b.ReportMetric(float64(total.done)/attempts, name+"-complete/attempt")
		b.ReportMetric(float64(total.calls)/attempts, name+"-sends/attempt")
		for i, label := range providerTimingLabels {
			b.ReportMetric(float64(total.timing[i])/attempts, name+"-"+label+"-ns/attempt")
		}
	}
}
