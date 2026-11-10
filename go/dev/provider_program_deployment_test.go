// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && schemeintegration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"os/exec"
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
	"github.com/HardenedLinux/weaver/go/internal/routing"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type configuredAuthority struct {
	Epoch    uint64            `json:"epoch"`
	Identity v1.SourceIdentity `json:"identity"`
}
type configuredProducer struct {
	Name      string              `json:"name"`
	Authority configuredAuthority `json:"authority"`
	Original  config.Bundle       `json:"original"`
}
type configuredCatalog struct {
	Producers []configuredProducer `json:"producers"`
}

func configuredCatalogPath(t testing.TB, f *fixture, bundle config.Bundle) string {
	t.Helper()
	// These values bind eligibility; actual mTLS/credential authentication
	// and the ledger's source floor remain mandatory at each source RPC.
	cert, err := x509.ParseCertificate(f.pki.source.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	leaf, key, credential := sha256.Sum256(cert.Raw), sha256.Sum256(cert.RawSubjectPublicKeyInfo), sha256.Sum256([]byte(adminToken))
	identity := v1.SourceIdentity{CertificateSHA256: hex.EncodeToString(leaf[:]), PublicKeySHA256: hex.EncodeToString(key[:]), CredentialSHA256: hex.EncodeToString(credential[:])}
	data, err := json.Marshal(configuredCatalog{Producers: []configuredProducer{{Name: "approved-control", Authority: configuredAuthority{Identity: identity}, Original: bundle}}})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(f.directory, "approved-catalog.json")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Logf("developer fixture catalog sha256=%x", sha256.Sum256(data))
	return path
}

func TestProviderControlCompiledProgramRevocationAndRestart(t *testing.T) {
	exerciseControlPolicies(t, "json", nil, compiledControlSources(false))
}

func TestProviderControlSingleProviderRetiresCompilerAfterActivation(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	bundle := controlBundle(t, f)
	f.env = append(f.env, "WEAVER_GOVERNANCE_RETIRE_ON_ACTIVATION=1")
	policy := compiledControlSources(false)
	policy.configure(t, f, bundle)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	prepared, err := f.admin.CompileSource(ctx, policy.producer)
	if err != nil {
		t.Fatal(err)
	}
	retired := func() bool {
		data, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
		if err != nil {
			t.Fatal(err)
		}
		return strings.Contains(string(data), "weaver governance stage=compiler-retired")
	}
	if retired() {
		t.Fatal("preparation retired before publication")
	}
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.useProducer(policy.producer)
	c.start(t)
	if !retired() {
		t.Fatal("activation did not await compiler cleanup")
	}
	replayed, err := f.admin.CompileSource(ctx, policy.producer)
	if err != nil || !proto.Equal(prepared, replayed) {
		t.Fatalf("retired preparation replay changed: %v", err)
	}
	if _, err := c.client.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err != nil || f.primary.Load() != 1 {
		t.Fatalf("activated provider unavailable after compiler retirement: %v", err)
	}
}

func TestProviderControlCompiledGovernorSuccessorUsesCompleteRelease(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	bundle := controlBundle(t, f)
	predecessor, successor := bundle.Plans[0], bundle.Plans[1]
	f.env = append(f.env, "WEAVER_GOVERNANCE_RETIRE_ON_ACTIVATION=1",
		hardFactFeedSetting(t, f, predecessor.Family, predecessor.Node,
			[][2]string{{successor.Node, predecessor.Node}},
			map[string]string{"predecessor": predecessor.Node, "successor": successor.Node}, "", nil))
	policy := compiledControlSources(false)
	policy.configure(t, f, bundle)
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.useProducer(policy.producer)
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	a := &pb.HardFactIntent{OperationId: "workflow-fact-a", Domain: "availability",
		Revision: 1, PreviousSnapshot: strings.Repeat("0", 64), Available: proto.Bool(true)}
	stage := func(intent *pb.HardFactIntent) *pb.HardFactBarrier {
		t.Helper()
		key, err := f.admin.RPC.StageHardFact(f.admin.Context(ctx), intent)
		if err != nil {
			t.Fatal(err)
		}
		return key
	}
	resolve := func(key *pb.HardFactBarrier) {
		t.Helper()
		result, err := f.admin.RPC.ResolveHardFact(f.admin.Context(ctx), key)
		if err != nil || strings.Join(result.GetAffected(), ",") != "infer,next" {
			t.Fatalf("native transitive impact: %v %v", result, err)
		}
	}
	attempt := func(plan v1.ProviderPlan) error {
		_, err := c.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
		return err
	}
	barrier := stage(a)
	resolve(barrier)
	if err := attempt(successor); status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 0 {
		t.Fatalf("successor advanced before response completion: %v", err)
	}
	if err := attempt(predecessor); err != nil || f.primary.Load() != 1 {
		t.Fatalf("predecessor did not complete: %v", err)
	}
	nextFact := stage(&pb.HardFactIntent{OperationId: "workflow-fact-b", Domain: a.Domain,
		Revision: 2, PreviousSnapshot: barrier.Snapshot, ExpectedFloor: barrier.Floor,
		Available: proto.Bool(true)})
	if err := attempt(successor); status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 1 {
		t.Fatalf("successor crossed pending fact floor: %v", err)
	}
	resolve(nextFact)
	if err := attempt(successor); err != nil || f.primary.Load() != 2 {
		t.Fatalf("completed release did not admit the exact successor: %v", err)
	}
	if err := attempt(successor); err == nil || f.primary.Load() != 2 || f.backup.Load() != 0 {
		t.Fatal("successor replay reset the original claim")
	}
	receipt, err := c.client.RPC.Inspect(c.client.Context(ctx), &pb.OperationKey{Family: successor.Family, Node: successor.Node})
	if err != nil || receipt.GetState() != "complete" || receipt.GetHeld() != 8 {
		t.Fatalf("successor completion or retained shared hold: %v %v", receipt, err)
	}
}

func TestProviderControlSessionWorkflowAutomaticallyResumes(t *testing.T) {
	t.Run("restart", func(t *testing.T) { exerciseAutomaticSession(t, false) })
	t.Run("withdrawal", func(t *testing.T) { exerciseAutomaticSession(t, true) })
}

func exerciseAutomaticSession(t *testing.T, withdraw bool) {
	t.Helper()
	rootEntered := make(chan struct{}, 1)
	releaseRoot := make(chan struct{})
	var release sync.Once
	unblock := func() { release.Do(func() { close(releaseRoot) }) }
	defer unblock()
	f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
			return
		}
		if !strings.Contains(string(body), `"content":"finish"`) {
			select {
			case rootEntered <- struct{}{}:
			default:
				t.Error("extra root send")
			}
			select {
			case <-releaseRoot:
			case <-r.Context().Done():
				return
			}
		}
		completeSSE(w, r)
	}, false)
	bundle := controlBundle(t, f)
	bundle.Governance.Schema = config.SessionWorkflowSchema
	bundle.Governance.OpenNodes = append(bundle.Governance.OpenNodes, "finish")
	task := &bundle.Tasks[0]
	task.Nodes = append(task.Nodes, "finish")
	task.Budget = 12
	finish := bundle.Plans[0]
	finish.Node = "finish"
	bundle.Plans = append(bundle.Plans, finish)
	for _, route := range bundle.Plans[1].Routes {
		if route.Target == "backup" {
			bundle.Plans[1].Routes = []v1.ProviderRoute{route}
			break
		}
	}
	for i := 1; i < len(bundle.Plans); i++ {
		step := &bundle.Plans[i]
		step.Body = strings.Replace(step.Body, `"hello"`, `"`+step.Node+`"`, 1)
		digest, err := step.Digest()
		if err != nil {
			t.Fatal(err)
		}
		body := sha256.Sum256([]byte(step.Body))
		task.BodyDigests[step.Node] = hex.EncodeToString(body[:])
		task.StreamContracts[step.Node] = digest
		task.NodeCostBounds[step.Node] = step.Ceiling
	}
	bundle.Publication.Policy = strings.Replace(bundle.Publication.Policy, `["infer", "next"]`, `["infer", "next", "finish"]`, 1)
	root, next, finish := bundle.Plans[0], bundle.Plans[1], bundle.Plans[2]
	f.env = append(f.env, `WEAVER_PROVIDER_CREDENTIAL_ENVS={"primary":"WEAVER_TEST_KEY"}`,
		"WEAVER_GOVERNANCE_RETIRE_ON_ACTIVATION=1",
		hardFactFeedSetting(t, f, root.Family, root.Node, [][2]string{{next.Node, root.Node}, {finish.Node, next.Node}},
			nil, config.SessionWorkflowSchema, nil, bundle.Governance.OpenNodes...))
	policy := compiledControlSources(false)
	policy.configure(t, f, bundle)
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.useProducer(policy.producer)
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	prepared, err := f.admin.CompileSource(ctx, policy.producer)
	if err != nil || prepared.GetArtifact().GetGovernance().GetSchema() != config.SessionWorkflowSchema ||
		strings.Join(prepared.GetArtifact().GetGovernance().GetOpenNodes(), ",") != "infer,next,finish" {
		t.Fatalf("native Session Workflow handoff: %v", err)
	}
	stage := func(revision uint64, previous *pb.HardFactBarrier, available bool) *pb.HardFactBarrier {
		t.Helper()
		snapshot := strings.Repeat("0", 64)
		if previous != nil {
			snapshot = previous.Snapshot
		}
		intent := &pb.HardFactIntent{OperationId: "session-fact-" + strconv.FormatUint(revision, 10),
			Domain: "availability", Revision: revision, PreviousSnapshot: snapshot, ExpectedFloor: previous.GetFloor(),
			Available: proto.Bool(available)}
		barrier, err := f.admin.RPC.StageHardFact(f.admin.Context(ctx), intent)
		if err != nil || barrier.GetFloor() != revision {
			t.Fatalf("stage fact %d: %v %v", revision, barrier, err)
		}
		return barrier
	}
	resolve := func(barrier *pb.HardFactBarrier) {
		t.Helper()
		result, err := f.admin.RPC.ResolveHardFact(f.admin.Context(ctx), barrier)
		if err != nil || !proto.Equal(barrier, result.GetBarrier()) ||
			strings.Join(result.GetAffected(), ",") != "finish,infer,next" {
			t.Fatalf("native ASCENT workflow closure: %v %v", result, err)
		}
	}
	attempt := func(step v1.ProviderPlan) error {
		_, err := c.client.Execute(ctx, step, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
		return err
	}
	receipt := func(step v1.ProviderPlan) (*pb.ProviderReceipt, error) {
		return c.client.RPC.Inspect(c.client.Context(ctx), &pb.OperationKey{Family: step.Family, Node: step.Node})
	}
	wait := func(step v1.ProviderPlan, state string, held uint64) *pb.ProviderReceipt {
		t.Helper()
		tick := time.NewTicker(20 * time.Millisecond)
		defer tick.Stop()
		digest, err := step.Digest()
		if err != nil {
			t.Fatal(err)
		}
		for {
			r, err := receipt(step)
			if err == nil && r.GetState() == state {
				if r.GetDigest() != digest || r.GetHeld() != held || r.GetReserved() != 4 ||
					(state == "complete" && r.GetEvents() == 0) {
					t.Fatalf("unexpected durable %s receipt: %v", step.Node, r)
				}
				return r
			}
			select {
			case <-tick.C:
			case <-ctx.Done():
				t.Fatalf("expected %s state %s: %v %v", step.Node, state, r, err)
			}
		}
	}
	assertSends := func(primary, backup int64) {
		t.Helper()
		if f.primary.Load() != primary || f.backup.Load() != backup || f.denied.Load() != 0 {
			t.Fatalf("upstream sends %d/%d/%d, want %d/%d/0", f.primary.Load(), f.backup.Load(), f.denied.Load(), primary, backup)
		}
	}
	waitFailed := func(expected uint64) {
		t.Helper()
		tick := time.NewTicker(20 * time.Millisecond)
		defer tick.Stop()
		for {
			m, err := f.admin.RPC.InspectTelemetry(f.admin.Context(ctx), &pb.Empty{})
			if err == nil && m.GetProviderFailed() >= expected {
				return
			}
			select {
			case <-tick.C:
			case <-ctx.Done():
				t.Fatalf("Session did not reconcile against withdrawal: %v %v", m, err)
			}
		}
	}
	duplicateRoot := func() {
		t.Helper()
		results := make(chan error, 2)
		for range 2 {
			go func() { results <- attempt(root) }()
		}
		for range 2 {
			if err := <-results; status.Code(err) != codes.FailedPrecondition {
				t.Fatalf("duplicate root unexpectedly executed: %v", err)
			}
		}
	}

	a := stage(1, nil, true)
	resolve(a)
	result := make(chan error, 1)
	go func() { result <- attempt(root) }()
	select {
	case <-rootEntered:
	case err := <-result:
		t.Fatalf("root did not reach upstream: %v", err)
	case <-ctx.Done():
		t.Fatal("root did not reach upstream")
	}
	if _, err := receipt(next); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("successor claimed before root release: %v", err)
	}
	assertSends(1, 0)
	unblock()
	if err := <-result; err != nil {
		t.Fatal(err)
	}

	queued := wait(next, "queued", 8)
	if err := attempt(next); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("operation caller took over Session successor: %v", err)
	}
	duplicateRoot()
	if retry := wait(next, "queued", 8); !proto.Equal(queued, retry) {
		t.Fatal("duplicate trigger changed the successor claim")
	}
	assertSends(1, 0)
	t.Log("complete release queued next automatically; duplicate triggers preserved its claim and held=8")
	var b *pb.HardFactBarrier
	if withdraw {
		b = stage(2, a, false)
	}
	c.stop(t)
	f.stop(t)
	f.env = append(f.env, `WEAVER_PROVIDER_CREDENTIAL_ENVS={"primary":"WEAVER_TEST_KEY","backup":"WEAVER_TEST_KEY"}`)
	f.start(t)
	c.start(t)
	if withdraw {
		if replay := stage(2, a, false); !proto.Equal(replay, b) {
			t.Fatal("restart changed the pending withdrawal")
		}
		waitFailed(1)
		wait(next, "queued", 8)
		assertSends(1, 0)
		resolve(b)
		waitFailed(2)
		duplicateRoot()
		wait(next, "queued", 8)
		assertSends(1, 0)
		t.Log("pending and resolved withdrawal fenced the already reserved successor after restart")
		resolve(stage(3, b, true))
	}
	// No Execute calls for either successor after restart. A late completion
	// or duplicate wake must continue under the original reservations.
	wait(finish, "complete", 12)
	wait(next, "complete", 12)
	duplicateRoot()
	assertSends(2, 1)
	t.Log("Session completed after restart; infer/finish primary=2 next backup=1 held=12")
}

func graphSessionBundle(t *testing.T, f *fixture, schema, backupNode string, budget uint64) config.Bundle {
	t.Helper()
	return sessionGraphBundle(t, f, config.Governance{
		Schema: schema, OpenNodes: []string{"infer", "next", "side", "finish"},
		WorkflowEdges: [][2]string{{"finish", "next"}, {"finish", "side"}, {"next", "infer"}, {"side", "infer"}},
	}, backupNode, budget)
}

func sessionGraphBundle(t *testing.T, f *fixture, governance config.Governance, backupNode string, budget uint64) config.Bundle {
	t.Helper()
	bundle := controlBundle(t, f)
	governance.Family = bundle.Governance.Family
	bundle.Governance = governance
	nodes := governance.OpenNodes
	task := &bundle.Tasks[0]
	task.Nodes = nodes
	task.Budget = budget
	root := bundle.Plans[0]
	bundle.Plans = []v1.ProviderPlan{root}
	for _, node := range nodes[1:] {
		step := root
		step.Node = node
		step.Body = strings.Replace(step.Body, `"hello"`, `"`+node+`"`, 1)
		if node == backupNode {
			for _, route := range step.Routes {
				if route.Target == "backup" {
					step.Routes = []v1.ProviderRoute{route}
					break
				}
			}
		}
		digest, err := step.Digest()
		if err != nil {
			t.Fatal(err)
		}
		body := sha256.Sum256([]byte(step.Body))
		task.BodyDigests[node] = hex.EncodeToString(body[:])
		task.StreamContracts[node] = digest
		task.NodeCostBounds[node] = step.Ceiling
		bundle.Plans = append(bundle.Plans, step)
	}
	nodeList, err := json.Marshal(nodes)
	if err != nil {
		t.Fatal(err)
	}
	bundle.Publication.Policy = strings.Replace(bundle.Publication.Policy, `["infer", "next"]`, string(nodeList), 1)
	return bundle
}

func TestProviderControlSessionDAGConcurrentJoinAndRecovery(t *testing.T) {
	arrived := make(chan string, 2)
	nextRelease, sideRelease := make(chan struct{}), make(chan struct{})
	var nextOnce, sideOnce sync.Once
	releaseNext := func() { nextOnce.Do(func() { close(nextRelease) }) }
	releaseSide := func() { sideOnce.Do(func() { close(sideRelease) }) }
	defer releaseNext()
	defer releaseSide()
	f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
			return
		}
		for node, release := range map[string]chan struct{}{"next": nextRelease, "side": sideRelease} {
			if strings.Contains(string(body), `"content":"`+node+`"`) {
				select {
				case arrived <- node:
				default:
					t.Error("duplicate branch send")
				}
				select {
				case <-release:
				case <-r.Context().Done():
					return
				}
				break
			}
		}
		completeSSE(w, r)
	}, false)
	bundle := graphSessionBundle(t, f, config.SessionDAGSchema, "finish", 16)
	root := bundle.Plans[0]
	nodes, edges := bundle.Governance.OpenNodes, bundle.Governance.WorkflowEdges
	f.env = append(f.env, `WEAVER_PROVIDER_CREDENTIAL_ENVS={"primary":"WEAVER_TEST_KEY"}`,
		hardFactFeedSetting(t, f, root.Family, root.Node, edges, nil, config.SessionDAGSchema, nil, nodes...))
	policy := compiledControlSources(false)
	policy.configure(t, f, bundle)
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.useProducer(policy.producer)
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	prepared, err := f.admin.CompileSource(ctx, policy.producer)
	if err != nil || len(prepared.GetArtifact().GetGovernance().GetWorkflowEdges()) != 4 {
		t.Fatalf("compiled Funflow topology: %v %v", prepared, err)
	}
	stage := func(revision uint64, prior *pb.HardFactBarrier, available bool) *pb.HardFactBarrier {
		t.Helper()
		snapshot := strings.Repeat("0", 64)
		if prior != nil {
			snapshot = prior.GetSnapshot()
		}
		r, err := f.admin.RPC.StageHardFact(f.admin.Context(ctx), &pb.HardFactIntent{
			OperationId: "dag-fact-" + strconv.FormatUint(revision, 10), Domain: "availability",
			Revision: revision, PreviousSnapshot: snapshot, ExpectedFloor: prior.GetFloor(), Available: proto.Bool(available),
		})
		if err != nil || r.GetFloor() != revision {
			t.Fatalf("stage DAG hard fact: %v %v", r, err)
		}
		return r
	}
	resolve := func(barrier *pb.HardFactBarrier) {
		t.Helper()
		r, err := f.admin.RPC.ResolveHardFact(f.admin.Context(ctx), barrier)
		if err != nil || !proto.Equal(r.GetBarrier(), barrier) || strings.Join(r.GetAffected(), ",") != "finish,infer,next,side" {
			t.Fatalf("resolve DAG hard fact: %v %v", r, err)
		}
	}
	inspect := func(node string) (*pb.ProviderReceipt, error) {
		return c.client.RPC.Inspect(c.client.Context(ctx), &pb.OperationKey{Family: root.Family, Node: node})
	}
	wait := func(node, state string, held uint64) *pb.ProviderReceipt {
		t.Helper()
		tick := time.NewTicker(20 * time.Millisecond)
		defer tick.Stop()
		for {
			r, err := inspect(node)
			if err == nil && r.GetState() == state && r.GetHeld() == held {
				return r
			}
			select {
			case <-tick.C:
			case <-ctx.Done():
				t.Fatalf("DAG %s expected %s, held %d: %v %v", node, state, held, r, err)
			}
		}
	}
	attemptRoot := func() error {
		_, err := c.client.Execute(ctx, root, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
		return err
	}
	a := stage(1, nil, true)
	resolve(a)
	if err := attemptRoot(); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for range 2 {
		select {
		case node := <-arrived:
			seen[node] = true
		case <-ctx.Done():
			t.Fatal("both branches must dispatch before either releases")
		}
	}
	if !seen["next"] || !seen["side"] {
		t.Fatalf("duplicate branch dispatch: %v", seen)
	}
	releaseNext()
	wait("next", "complete", 12)
	if _, err := inspect("finish"); status.Code(err) != codes.FailedPrecondition || f.backup.Load() != 0 {
		t.Fatalf("join admitted with just one release: %v", err)
	}
	releaseSide()
	queued := wait("finish", "queued", 16)
	for range 2 {
		if err := attemptRoot(); status.Code(err) != codes.FailedPrecondition {
			t.Fatalf("root replay: %v", err)
		}
	}
	if replay := wait("finish", "queued", 16); !proto.Equal(replay, queued) {
		t.Fatal("duplicate reconciliation replaced join claim")
	}
	t.Log("both branches dispatched concurrently; one release did not admit join; two releases reserved join once")
	b := stage(2, a, false)
	c.stop(t)
	f.stop(t)
	f.env = append(f.env, `WEAVER_PROVIDER_CREDENTIAL_ENVS={"primary":"WEAVER_TEST_KEY","backup":"WEAVER_TEST_KEY"}`)
	f.start(t)
	c.start(t)
	if replay := stage(2, a, false); !proto.Equal(replay, b) {
		t.Fatal("restart changed the withdrawal barrier")
	}
	wait("finish", "queued", 16)
	resolve(b)
	if err := attemptRoot(); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("root replay crossed withdrawal: %v", err)
	}
	wait("finish", "queued", 16)
	if f.primary.Load() != 3 || f.backup.Load() != 0 {
		t.Fatal("join sent under withdrawal or a predecessor repeated")
	}
	resolve(stage(3, b, true))
	finished := wait("finish", "complete", 16)
	if finished.GetDigest() != queued.GetDigest() || finished.GetReserved() != 4 ||
		finished.GetEvents() == 0 || f.primary.Load() != 3 || f.backup.Load() != 1 || f.denied.Load() != 0 {
		t.Fatalf("recovered join receipt and sends: %v %d/%d/%d", finished, f.primary.Load(), f.backup.Load(), f.denied.Load())
	}
	if err := attemptRoot(); status.Code(err) != codes.FailedPrecondition || f.backup.Load() != 1 {
		t.Fatalf("completed join replay: %v", err)
	}
	t.Log("restart and withdrawal retained join; restored facts released it once; primary=3 backup=1 held=16")
}

func TestProviderControlCompiledProgramSharedBudgetRejectsConcurrentSendAndSDKRetry(t *testing.T) {
	exerciseControlSharedBudgetPolicies(t, nil, compiledControlSources(false))
}

func TestProviderControlCompiledPreflightCannotAuthorize(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	bundle := controlBundle(t, f)
	bundle.Publication.Policy = "forbid(principal,action,resource);"
	policy := compiledControlSources(false)
	policy.configure(t, f, bundle)
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.useProducer(policy.producer)
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	_, err := c.client.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1,
		func(*pb.Event) error { t.Error("inert preflight authorized an effect"); return nil })
	if status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("compiled Scheme/Cedar preflight bypassed final Policy", err)
	}
}

func TestProviderControlCompiledAssetsRevocationAndRestart(t *testing.T) {
	exerciseControlPolicies(t, "json", nil, compiledControlSources(true))
}

func compiledControlSources(assets bool) controlPolicySources {
	return composedControlSources(assets, false)
}

func TestProviderControlSchemeCompositionRevocationAndRestart(t *testing.T) {
	exerciseControlPolicies(t, "json", nil, composedControlSources(false, true))
}

func composedControlSources(assets, compose bool) controlPolicySources {
	return controlPolicySources{producer: "approved-control", configure: func(t *testing.T, f *fixture, bundle config.Bundle) {
		path := configuredCatalogPath(t, f, bundle)
		if compose {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var catalog struct {
				Producers []map[string]any `json:"producers"`
			}
			if err := json.Unmarshal(data, &catalog); err != nil {
				t.Fatal(err)
			}
			raw := bundle
			raw.Tasks = append([]v1.Task(nil), bundle.Tasks...)
			raw.Tasks[0].BodyDigests = map[string]string{}
			raw.Tasks[0].StreamContracts = map[string]string{}
			raw.Plans = []v1.ProviderPlan{}
			choices := make([]routing.Selection, 0, len(bundle.Plans))
			for _, plan := range bundle.Plans {
				invalid := plan
				invalid.Body = `{}`
				choices = append(choices, routing.Selection{Node: plan.Node,
					AllowedModules: []string{"approved"}, Required: []string{"text"},
					MaxLatencyMillis: 100, MaxProcurementCost: 4,
					Candidates: []routing.Candidate{{Module: "approved", Capabilities: []string{"text"},
						LatencyMillis: 10, TokenBounds: [4]uint64{0, 0, 0, 32}, Plan: plan},
						{Module: "approved", Capabilities: []string{"text"}, LatencyMillis: 1, TokenBounds: [4]uint64{0, 0, 0, 32}, Plan: invalid}},
				})
			}
			delete(catalog.Producers[0], "original")
			catalog.Producers[0]["composition"] = map[string]any{"source": raw, "routing": choices}
			data, err = json.Marshal(catalog)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
		}
		f.stop(t)
		f.env = append(f.env, "WEAVER_GOVERNANCE_CATALOG="+path)
		if assets {
			assetRoot := filepath.Join(f.directory, "governance-assets")
			if err := os.Mkdir(assetRoot, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(assetRoot, "policy.cedar"), []byte(bundle.Publication.Policy), 0600); err != nil {
				t.Fatal(err)
			}
			f.env = append(f.env, "WEAVER_TEST_GOVERNANCE_ASSET_ROOT="+assetRoot)
		}
		f.start(t)
		// CompileSource returns the frozen source artifact, never the reviewer's
		// approval. Register the existing independent issuer's exact review
		// before the real control process stages and finalizes that original.
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		reviewer, ok := f.admin.RPC.(*fixtureReviewer)
		if !ok {
			t.Fatal("independent fixture reviewer missing")
		}
		approved, err := reviewer.review(f.admin.Context(ctx), bundle.Publication)
		if err != nil || approved == nil {
			t.Fatalf("compiled source bootstrap review: %v", err)
		}
		wire, err := gatewayclient.ReviewMessage(*approved)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.admin.RPC.RegisterPublicationReview(f.admin.Context(ctx), wire); err != nil {
			t.Fatal(err)
		}
	}}
}

func TestProviderControlCompiledAssetsPublicationReplyLossAndRestart(t *testing.T) {
	exerciseControlSourceReplyLoss(t, nil, false, compiledControlSources(true))
}

func TestProviderControlCompiledAssetsStagingReplyLossAndRestart(t *testing.T) {
	exerciseControlSourceReplyLoss(t, nil, true, compiledControlSources(true))
}

func TestProviderRustDirectPreparationLostReplies(t *testing.T) {
	t.Run("staging", func(t *testing.T) {
		exerciseSourceReplyLoss(t, nil, true, compiledControlSources(true), serverBinary)
	})
	t.Run("publication", func(t *testing.T) {
		exerciseSourceReplyLoss(t, nil, false, compiledControlSources(true), serverBinary)
	})
}

func TestProviderControlCompiledAssetsPartialRequestAndRestart(t *testing.T) {
	f := newFixture(t, partialRequestDisconnect, true)
	bundle := controlBundle(t, f)
	policy := compiledControlSources(true)
	policy.configure(t, f, bundle)
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.useProducer(policy.producer)
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	plan := bundle.Plans[0]
	if _, err := c.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("partial request accepted as complete")
	}
	key := &pb.OperationKey{Family: plan.Family, Node: plan.Node}
	before, err := c.client.RPC.Inspect(c.client.Context(ctx), key)
	if err != nil || before.GetState() != "unknown" || before.GetHeld() != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatal("partial execution lost its original hold", before, err)
	}
	cancel()
	c.stop(t)
	f.stop(t)
	f.start(t)
	c.start(t)
	ctx, cancel = context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if _, err := c.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("restart or SDK retry reopened the consumed claim")
	}
	after, err := c.client.RPC.Inspect(c.client.Context(ctx), key)
	if err != nil || !proto.Equal(before, after) || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatal("restart duplicated the send or released unknown budget", after, err)
	}
}

func TestProviderControlCompiledProgramRequiresRealInstallation(t *testing.T) {
	if _, approvedApplication := os.LookupEnv("WEAVER_GOVERNANCE_APPLICATION"); approvedApplication {
		t.Skip("the skip-install control is supplied by the debug Scheme fixture")
	}
	f := newFixture(t, completeSSE, false)
	path := configuredCatalogPath(t, f, controlBundle(t, f))
	f.stop(t)
	// The application is linked and initialized, but deliberately does not
	// register its producer. No mock readiness response or forced exit is used.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, serverBinary)
	cmd.Env = append(append(os.Environ(), f.env...), "WEAVER_GOVERNANCE_CATALOG="+path, "WEAVER_TEST_SKIP_PROGRAM_INSTALL=1")
	started := time.Now()
	output, err := cmd.CombinedOutput()
	if ctx.Err() != nil || err == nil || time.Since(started) > 3*time.Second {
		t.Fatalf("missing installation did not refuse naturally within startup gate: %v %s", err, output)
	}
	if !strings.Contains(string(output), "governance initialization failed") || strings.Contains(string(output), "stage=listeners-bound") {
		t.Fatalf("uninstalled application reached serving or failed elsewhere: %s", output)
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("initialization refusal sent provider traffic")
	}
}

func TestProviderControlCompiledCatalogRequiresExactSourceEpoch(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	path := configuredCatalogPath(t, f, controlBundle(t, f))
	good, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var catalog configuredCatalog
	if err := json.Unmarshal(good, &catalog); err != nil {
		t.Fatal(err)
	}
	catalog.Producers[0].Authority.Epoch = 1
	wrongEpoch, err := json.Marshal(catalog)
	if err != nil {
		t.Fatal(err)
	}
	f.stop(t)
	if err := os.WriteFile(path, wrongEpoch, 0600); err != nil {
		t.Fatal(err)
	}
	f.env = append(f.env, "WEAVER_GOVERNANCE_CATALOG="+path, "WEAVER_TEST_GOVERNOR_TIMING=1")
	f.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	authority, err := f.admin.SourceAuthority(ctx)
	if err != nil || authority.GetEpoch() != 0 {
		t.Fatalf("expected authoritative epoch zero: %v %v", authority, err)
	}
	if reply, err := f.admin.CompileSource(ctx, "approved-control"); reply != nil || status.Code(err) != codes.PermissionDenied {
		t.Fatalf("catalog epoch mismatch crossed source admission: %v %v", reply, err)
	}
	f.stop(t)
	negative, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(negative), "weaver scheme phase=compile-begin") ||
		strings.Contains(string(negative), "weaver scheme phase=source-captured") {
		t.Fatal("catalog epoch mismatch entered Scheme capture")
	}
	t.Log("authenticated source epoch mismatch rejected before Scheme capture and naturally drained")
	if err := os.WriteFile(path, good, 0600); err != nil {
		t.Fatal(err)
	}
	f.start(t)
	exact, stop := context.WithTimeout(context.Background(), 12*time.Second)
	defer stop()
	if reply, err := f.admin.CompileSource(exact, "unapproved-control"); reply != nil || status.Code(err) != codes.PermissionDenied {
		t.Fatalf("unknown producer crossed source admission: %v %v", reply, err)
	}
	reply, err := f.admin.CompileSource(exact, "approved-control")
	if err != nil || reply.GetArtifact() == nil || reply.GetAuthority().GetEpoch() != 0 ||
		reply.GetAuthority().GetIdentityDigest() != authority.GetIdentityDigest() {
		t.Fatalf("exact catalog epoch and identity did not compile: %v %v", reply, err)
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("compile-only source RPC sent provider traffic")
	}
	f.stop(t)
	positive, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(positive), "weaver scheme phase=source-captured") {
		t.Fatal("matching source epoch did not execute Scheme capture")
	}
	t.Log("exact epoch and producer compiled after restart, with zero provider sends")
}

// The preparation command has source credentials only and exits before any
// operation request. All frames then travel directly from the Rust listener.
func TestProviderRustDirectPreparedOperationWithoutGoRelay(t *testing.T) {
	checkDirectPreparedOperation(t, "", false)
}

func TestProviderRustDirectPreparationCommand(t *testing.T) {
	checkDirectPreparedOperation(t, serverBinary, false)
}

func TestProviderRustDirectPreparationFromTOML(t *testing.T) {
	checkDirectPreparedOperation(t, serverBinary, true)
}

func checkDirectPreparedOperation(t *testing.T, preparationImage string, useTOML bool) {
	t.Helper()
	f := newFixture(t, completeSSE, false)
	bundle := controlBundle(t, f)
	f.env = append(f.env, "WEAVER_GOVERNANCE_RETIRE_ON_ACTIVATION=1")
	policy := compiledControlSources(false)
	policy.configure(t, f, bundle)
	control := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	control.useProducer(policy.producer)
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	if preparationImage == "" {
		preparationImage = control.image
	}
	command := control.prepareCommand(ctx, preparationImage, "prepare")
	if useTOML {
		command = sourceTOMLCommand(t, control, command)
	}
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("source-only preparation: %v: %s", err, output)
	}
	// A dangling modification must not be interpreted as an operation-key call.
	stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{Plan: &pb.ProviderPlan{Family: "control", Node: "infer", Profile: "changed"}, Encoding: pb.Encoding_PROTOBUF, BatchRows: 1})
	if err == nil {
		_, err = stream.Recv()
	}
	if err == nil || f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("modified original admitted", err)
	}
	stream, err = f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{Plan: &pb.ProviderPlan{Family: "control", Node: "infer"}, Encoding: pb.Encoding_PROTOBUF, BatchRows: 1})
	if err != nil {
		t.Fatal(err)
	}
	frames := 0
	text := ""
	for {
		frame, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if frame.GetEvent() == nil {
			t.Fatal("empty released frame")
		}
		text += frame.GetEvent().Text
		frames++
	}
	if frames != 5 || text != "hello world" || f.primary.Load()+f.backup.Load() != 1 {
		t.Fatal("direct operation incomplete", frames)
	}
	if control.child != nil {
		t.Fatal("Go service remained in the request path")
	}
	f.stop(t)
	f.start(t)
	stream, err = f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{Plan: &pb.ProviderPlan{Family: "control", Node: "infer"}, Encoding: pb.Encoding_PROTOBUF, BatchRows: 1})
	if err == nil {
		_, err = stream.Recv()
	}
	if err == nil || f.primary.Load()+f.backup.Load() != 1 {
		t.Fatal("restart replayed completed original", err)
	}
}

func sourceTOMLCommand(t *testing.T, control *controlProcess, command *exec.Cmd, kubernetes ...string) *exec.Cmd {
	t.Helper()
	settings := make(map[string]string)
	environment := command.Env[:0]
	for _, value := range command.Env {
		name, text, _ := strings.Cut(value, "=")
		if strings.HasPrefix(name, "WEAVER_CONTROL_") {
			settings[name] = text
			continue
		}
		environment = append(environment, value)
	}
	const tokenEnv = "WEAVER_TEST_PREPARATION_TOKEN"
	var config strings.Builder
	config.WriteString("[source]\n")
	for _, field := range []struct{ key, env string }{
		{"producer", "WEAVER_CONTROL_PRODUCER"},
		{"file", "WEAVER_CONTROL_CONFIG"},
		{"address", "WEAVER_CONTROL_AUTHORITY_SOURCE_ADDRESS"},
		{"server_name", "WEAVER_CONTROL_AUTHORITY_SERVER_NAME"},
		{"ca", "WEAVER_CONTROL_AUTHORITY_CA"},
		{"certificate", "WEAVER_CONTROL_AUTHORITY_SOURCE_CERT"},
		{"key", "WEAVER_CONTROL_AUTHORITY_SOURCE_KEY"},
	} {
		value := settings[field.env]
		if (field.key == "producer" || field.key == "file") && (len(kubernetes) != 0 || value == "") {
			continue
		}
		if field.key == "ca" || field.key == "certificate" || field.key == "key" || field.key == "file" {
			var err error
			value, err = filepath.Rel(control.directory, value)
			if err != nil {
				t.Fatal(err)
			}
		}
		config.WriteString(field.key + " = " + strconv.Quote(value) + "\n")
	}
	config.WriteString("token_env = " + strconv.Quote(tokenEnv) + "\n")
	for _, section := range kubernetes {
		config.WriteString(section)
	}
	path := filepath.Join(control.directory, "weaver.toml")
	if err := os.WriteFile(path, []byte(config.String()), 0600); err != nil {
		t.Fatal(err)
	}
	command.Args = append(command.Args, "--config", path)
	command.Env = append(environment, tokenEnv+"="+settings["WEAVER_CONTROL_AUTHORITY_SOURCE_TOKEN"])
	return command
}

// File source preparation also retains exact plans for direct operation keys;
// it does not rely on the optional compiled single-provider retirement profile.
func TestProviderRustDirectFilePreparation(t *testing.T) {
	for _, format := range []string{"json", "yaml"} {
		t.Run(format, func(t *testing.T) { checkDirectFilePreparation(t, format) })
	}
}

func checkDirectFilePreparation(t *testing.T, format string) {
	t.Helper()
	f := newFixture(t, completeSSE, false)
	bundle := controlBundle(t, f)
	originalPolicy := bundle.Publication.Policy
	bundle.Publication.Policy += `
forbid(principal, action == Weaver::Action::"invokeProvider", resource) when { context.family == "control" && context.node == "next" };`
	control := newControlProcess(t, f, writeControlBundle(t, f, bundle, format))
	if format == "yaml" {
		ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
		command := sourceTOMLCommand(t, control, control.prepareCommand(ctx, serverBinary, "prepare"))
		output, err := command.CombinedOutput()
		cancel()
		if err != nil {
			t.Fatalf("source-only preparation from TOML file: %v: %s", err, output)
		}
	} else {
		control.prepareUsing(t, serverBinary, "prepare")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	run := func() error {
		stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{Plan: &pb.ProviderPlan{Family: "control", Node: "infer"}, Encoding: pb.Encoding_PROTOBUF, BatchRows: 1})
		if err != nil {
			return err
		}
		count := 0
		text := ""
		for {
			frame, err := stream.Recv()
			if err == io.EOF {
				if count != 5 || text != "hello world" {
					t.Fatalf("incomplete direct file stream: count=%d text=%q", count, text)
				}
				return nil
			}
			if err != nil {
				return err
			}
			count++
			text += frame.GetEvent().GetText()
		}
	}
	if err := run(); err != nil {
		t.Fatal(err)
	}
	if f.primary.Load() != 1 || control.child != nil {
		t.Fatal("direct file operation path", f.primary.Load())
	}
	deniedNext := func() {
		stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{Plan: &pb.ProviderPlan{Family: "control", Node: "next"}, Encoding: pb.Encoding_PROTOBUF, BatchRows: 1})
		if err == nil {
			_, err = stream.Recv()
		}
		if status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 1 {
			t.Fatalf("fixed projection used stale authority: %v", err)
		}
	}
	deniedNext() // Warm exact immutable data while Cedar denies execution.
	for index, policy := range []string{originalPolicy, bundle.Publication.Policy} {
		publication := bundle.Publication.Clone()
		revision := uint64(index + 1)
		publication.OperationID = "fixed-policy-" + strconv.Itoa(index)
		publication.ExpectedRevision = &revision
		publication.Fence = uint64(index + 2)
		publication.Policy = policy
		if _, err := f.admin.Publish(ctx, publication); err != nil {
			t.Fatal(err)
		}
		deniedNext() // Even newly allowing Cedar cannot rebase the old plan.
	}
	f.stop(t)
	f.start(t)
	if err := run(); err == nil || f.primary.Load() != 1 {
		t.Fatal("restart replayed file original", err)
	}
}

func TestProviderRustDirectFixedPlanSurvivesSourceHandoff(t *testing.T) {
	for _, mode := range []string{"warm", "cold", "restart"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t, completeSSE, false)
			bundle := controlBundle(t, f)
			newControlProcess(t, f, writeControlBundle(t, f, bundle, "json")).prepare(t)
			ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
			defer cancel()
			call := func(catalog string) error {
				stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{
					Plan: &pb.ProviderPlan{Family: "control", Node: "next"}, BatchRows: 1, CatalogVersion: catalog,
				})
				if err != nil {
					return err
				}
				for {
					frame, err := stream.Recv()
					if err == io.EOF {
						return nil
					}
					if err != nil {
						return err
					}
					if frame.GetEvent() == nil {
						t.Fatal("expected protobuf event")
					}
				}
			}
			if mode == "warm" {
				// Resolve the original while rejecting the caller's catalog precondition.
				if err := call(strings.Repeat("a", 64)); status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 0 {
					t.Fatalf("catalog precondition consumed fixed plan: %v", err)
				}
			}
			next := secondaryClient(t, f.pki)
			token := sha256.Sum256([]byte(f.admin.Token))
			rotation := v1.SourceRotation{OperationID: "fixed-source-handoff", ExpectedEpoch: 0, NextCertificate: next.Certificate[0], NextCredentialSHA256: hex.EncodeToString(token[:])}
			if receipt, err := f.admin.RotateSource(ctx, rotation); err != nil || receipt.GetAuthority().GetEpoch() != 1 {
				t.Fatalf("source handoff: %v %v", receipt, err)
			}
			if _, err := f.admin.SourceAuthority(ctx); status.Code(err) != codes.PermissionDenied {
				t.Fatalf("retired source retained mutation identity: %v", err)
			}
			if mode == "restart" {
				restartWithSourceCertificate(t, f, next)
			}
			if err := call(""); err != nil || f.primary.Load() != 1 || f.backup.Load() != 0 {
				t.Fatalf("fixed publication changed after source handoff: sends=%d error=%v", f.primary.Load(), err)
			}
		})
	}
}
