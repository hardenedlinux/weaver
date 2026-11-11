// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"cmp"
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"golang.org/x/sys/unix"
)

type controlFrameSample struct {
	family         string
	node           string
	wave           int
	started, first int64
	received       map[uint64]int64
	frameGaps      []time.Duration
}
type controlBenchArm struct {
	frames []controlFrameSample

	f                     *fixture
	control               [4]*controlProcess
	plans                 [4][]v1.ProviderPlan
	activation            []time.Duration
	latency, recv, decode []time.Duration
	wall                  time.Duration
}

func providerObservationNanos() int64 {
	var stamp unix.Timespec
	if err := unix.ClockGettime(unix.CLOCK_MONOTONIC, &stamp); err != nil {
		panic(err)
	}
	return stamp.Nano()
}

// Four independently bootstrapped task owners each expose 32 distinct original
// nodes. Both arms activate through Go; only the measured request path differs.
// Cold activation stays separate from the 128 warm, exactly-once operations.
func BenchmarkProviderGoControlPair(b *testing.B) {
	benchmarkProviderGoControlPair(b, burstProviderSSE(13))
}

func BenchmarkProviderGoControlPacedPair(b *testing.B) {
	benchmarkProviderGoControlPair(b, pacedControlSSE)
}

func pacedControlSSE(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for event := range 12 {
		if event != 0 {
			select {
			case <-r.Context().Done():
				return
			case <-tick.C:
			}
		}
		switch {
		case event < 10:
			emitChunk(w, "delta", false)
		case event == 10:
			emitChunk(w, "", true)
		default:
			fmt.Fprint(w, providerUsageAndDone)
		}
	}
}

func benchmarkProviderGoControlPair(b *testing.B, handler http.HandlerFunc) {
	reusePair := os.Getenv("WEAVER_TEST_PROVIDER_CONNECTION_PAIR") == "1"
	tracePair := os.Getenv("WEAVER_TEST_PROVIDER_TRACE_PAIR") == "1"
	plansPair := os.Getenv("WEAVER_TEST_PROVIDER_CURRENTNESS_PAIR") == "1"
	manifestMode := os.Getenv("WEAVER_TEST_PROVIDER_MANIFEST_PAIR")
	manifestAA := manifestMode == "aa"
	evidencePair := manifestMode == "evidence"
	manifestPair := manifestMode == "1" || manifestAA || evidencePair
	baseline, bindingPair := os.LookupEnv("WEAVER_TEST_CONTROL_BASELINE_IMAGE")
	providerBaseline, providerPair := os.LookupEnv("WEAVER_TEST_PROVIDER_BASELINE_IMAGE")
	rustHeapPair := os.Getenv("WEAVER_TEST_RUST_HEAP_LIBRARY") != ""
	if rustHeapPair && (reusePair || tracePair || plansPair || (manifestPair && !evidencePair) || bindingPair) {
		b.Fatal("Rust heap comparison requires exclusive custody of the diagnostic arm")
	}
	if bindingPair && (reusePair || tracePair || plansPair || manifestPair || !filepath.IsAbs(baseline)) {
		b.Fatal("binding comparison requires an exclusive absolute baseline image")
	}
	if tracePair && (reusePair || os.Getenv("WEAVER_TEST_PROVIDER_SCOPE_TRACE") != "") {
		b.Fatal("trace comparison requires exclusive custody of the trace setting")
	}
	if plansPair && (reusePair || tracePair || os.Getenv("WEAVER_TEST_CACHE_CURRENTNESS_PLANS") != "") {
		b.Fatal("currentness comparison requires exclusive custody of the SQL cache setting")
	}
	if manifestPair && (reusePair || tracePair || plansPair || os.Getenv("WEAVER_TEST_PREPARED_MANIFEST_PROGRAMS") != "" || os.Getenv("WEAVER_TEST_CACHE_CURRENTNESS_PLANS") != "") {
		b.Fatal("manifest comparison requires exclusive custody of program preparation")
	}
	if evidencePair && os.Getenv("WEAVER_TEST_PREPARED_ORIGINAL_PROGRAM") != "" {
		b.Fatal("evidence comparison requires exclusive custody of original program preparation")
	}
	// TestMain stages and verifies the frozen production image before benchmarks.
	production := os.Getenv("WEAVER_TEST_PREBUILT_PROVIDER_IMAGE") != "" &&
		!(reusePair || tracePair || plansPair || manifestPair || bindingPair || rustHeapPair)
	if providerPair && (!production || !filepath.IsAbs(providerBaseline)) {
		b.Fatal("Rust release comparison requires a frozen production image and an absolute baseline image")
	}
	image := serverBinary
	if !production {
		image = wifImage(b, true)
	}
	labels := [2]string{"direct-rust", "go-control"}
	if reusePair {
		labels = [2]string{"fresh", "reuse"}
	}
	if tracePair {
		labels = [2]string{"light", "traced"}
	}
	if plansPair {
		labels = [2]string{"fresh-plans", "cached-plans"}
	}
	if manifestPair {
		labels = [2]string{"fresh-manifest", "prepared-manifest"}
	}
	if manifestAA {
		labels = [2]string{"fresh-manifest-a", "fresh-manifest-b"}
	}
	if rustHeapPair && !evidencePair {
		labels = [2]string{"without-heap-counters", "with-heap-counters"}
	}
	controlImages := [2]string{controlBinary, controlBinary}
	providerImages := [2]string{image, image}
	if providerPair {
		providerImages[0] = filepath.Join(b.TempDir(), "weaver-server-baseline")
		digest, err := publishProviderImage(providerBaseline, providerImages[0])
		if err != nil || digest != os.Getenv("WEAVER_TEST_PROVIDER_BASELINE_SHA256") {
			b.Fatalf("Rust baseline image does not match the frozen digest: %s %v", digest, err)
		}
		b.Logf("Rust baseline image sha256=%s; both arms use Go forwarding", digest)
		labels = [2]string{"baseline-rust", "candidate-rust"}
	}
	if bindingPair {
		controlImages[0] = filepath.Join(b.TempDir(), "weaver-control-baseline")
		digest, err := publishProviderImage(baseline, controlImages[0])
		if err != nil || digest != os.Getenv("WEAVER_TEST_CONTROL_BASELINE_SHA256") {
			b.Fatalf("control baseline image does not match the frozen digest: %s %v", digest, err)
		}
		b.Logf("Go control baseline image sha256=%s", digest)
		labels = [2]string{"projected-binding", "wire-binding"}
	}
	trace := [2]bool{!tracePair, true}
	if production {
		trace = [2]bool{}
	}
	for _, shared := range []bool{false, true} {
		for _, encoding := range []pb.Encoding{pb.Encoding_PROTOBUF, pb.Encoding_ARROW_IPC} {
			rows := uint32(1)
			if encoding == pb.Encoding_ARROW_IPC {
				rows = 4
			}
			b.Run(fmt.Sprintf("shared=%t/encoding=%s/rows=%d", shared, encoding, rows), func(b *testing.B) {
				b.StopTimer()
				var arms [2]*controlBenchArm
				for i := range arms {
					var env []string
					if reusePair && i == 1 {
						env = append(env, "WEAVER_TEST_REUSE_PROVIDER_CONNECTION=1")
					}
					if rustHeapPair && (i == 1 || evidencePair) {
						env = append(env, "WEAVER_TEST_RUST_HEAP_ARM=1")
					}
					if plansPair {
						env = append(env, fmt.Sprintf("WEAVER_TEST_CACHE_CURRENTNESS_PLANS=%d", i))
					}
					if manifestPair {
						prepared := i == 1 && !manifestAA
						if prepared {
							env = append(env, "WEAVER_TEST_PREPARED_MANIFEST_PROGRAMS=1")
						} else {
							env = append(env, "WEAVER_TEST_PREPARED_MANIFEST_PROGRAMS=0")
						}
					}
					if evidencePair {
						env = append(env, fmt.Sprintf("WEAVER_TEST_PREPARED_ORIGINAL_PROGRAM=%d", i))
					}
					arms[i] = newControlBenchArm(b, providerImages[i], controlImages[i], 32*b.N, shared, trace[i], production, handler, env...)
				}
				account := providerPair || tracePair || plansPair || manifestPair || rustHeapPair ||
					os.Getenv("WEAVER_TEST_PROVIDER_PROCESS_ACCOUNTING") == "1" || os.Getenv("WEAVER_TEST_CONTROL_HEAP") == "1"
				var accounting controlAccounting
				if account {
					accounting = startControlAccounting(b, arms)
				}
				b.StartTimer()
				for wave := range 32 * b.N {
					for _, i := range []int{wave % 2, 1 - wave%2} {
						arm := arms[i]
						began := time.Now()
						type result struct {
							owner     int
							events    int
							transport domainStreamTransport
							latency   time.Duration
							started   int64
							err       error
						}
						results := make(chan result, 4)
						start := make(chan struct{})
						for owner := range 4 {
							go func() {
								client := arm.f.client
								if i == 1 || providerPair || reusePair || tracePair || plansPair || manifestPair || bindingPair || rustHeapPair {
									client = arm.control[owner].client
								}
								ctx, cancel := context.WithTimeout(b.Context(), 12*time.Second)
								defer cancel()
								<-start
								at := time.Now()
								started := providerObservationNanos()
								n, timing, err := readDomainProgramStreamTimed(ctx, client, arm.plans[owner][wave], encoding, rows, nil, providerObservationNanos)
								results <- result{owner, n, timing, time.Since(at), started, err}
							}()
						}
						close(start)
						for range 4 {
							r := <-results
							if r.err != nil || r.events != 13 || r.transport.frames != (13+int(rows)-1)/int(rows) {
								b.Fatalf("control stream completion: %+v", r)
							}
							plan := arm.plans[r.owner][wave]
							arm.frames = append(arm.frames, controlFrameSample{plan.Family, plan.Node, wave, r.started, r.transport.firstTick, r.transport.received, r.transport.frameGaps})
							arm.latency = append(arm.latency, r.latency)
							arm.recv = append(arm.recv, r.transport.recv)
							arm.decode = append(arm.decode, r.transport.decode)
						}
						arm.wall += time.Since(began)
					}
				}
				b.StopTimer()
				if account {
					accounting.finish(b, arms, labels, 32*b.N*4)
				}
				b.ReportMetric(0, "ns/op")
				for i, label := range labels {
					arm := arms[i]
					verifyControlBenchArm(b, arm, shared)
					for _, owner := range arm.control {
						owner.stop(b)
					}
					// The server writes observations when workers finish. Read
					// them after natural exit, outside the timed section.
					arm.f.stop(b)
					b.ReportMetric(float64(len(arm.latency))/arm.wall.Seconds(), label+"-complete/s")
					b.ReportMetric(tailMillis(arm.latency, 99), label+"-stream-p99-ms")
					if trace[i] {
						b.ReportMetric(tailMillis(controlFrameLatencies(b, arm), 99), label+"-rust-queue-to-client-p99-ms/frame")
						reportControlFirstFrame(b, arm, label)
					} else {
						assertNoControlTrace(b, arm)
					}
					first, gaps := controlArrivalLatencies(b, arm)
					b.ReportMetric(tailMillis(first, 99), label+"-first-frame-p99-ms/stream")
					b.ReportMetric(tailMillis(gaps, 99), label+"-inter-frame-p99-ms/frame")
					b.ReportMetric(tailMillis(arm.recv, 99), label+"-grpc-recv-p99-ms/stream")
					b.ReportMetric(tailMillis(arm.decode, 99), label+"-decode-p99-ms/stream")
					for j, duration := range arm.activation {
						b.ReportMetric(float64(duration.Nanoseconds())/1e6, fmt.Sprintf("%s-cold-owner%d-ms", label, j))
					}
				}
			})
		}
	}
}

func newControlBenchArm(t testing.TB, image, controlImage string, nodes int, shared, trace, production bool, handler http.HandlerFunc, extraEnv ...string) *controlBenchArm {
	t.Helper()
	if nodes > 64 {
		t.Fatal("frozen control benchmark supports at most 64 nodes per task; use -benchtime=1x")
	}
	env := append([]string{"WEAVER_STORAGE_JOURNAL=mvcc"}, extraEnv...)
	if trace {
		env = append(env, "WEAVER_TEST_PROVIDER_SCOPE_TRACE=1")
	}
	arguments := []string{"--exact", "grpc_config::serve_wif_gateway", "--ignored", "--nocapture"}
	if production {
		arguments = nil
	}
	f := providerFixture(t, handler, false, image, arguments, env, providerProfile(), nil, nil)
	arm := &controlBenchArm{f: f}
	families := []string{"controlbench-0", "controlbench-1", "controlbench-2", "controlbench-3"}
	parent := uint64(0)
	policy := f.policy + `
permit(principal == Weaver::Principal::"alice", action in [Weaver::Action::"admitProvider", Weaver::Action::"invokeProvider", Weaver::Action::"emitProvider"], resource)
when { ["controlbench-0","controlbench-1","controlbench-2","controlbench-3"].contains(context.family) && context.profile == "p" && context.model == "model-a" && context.profile_digest != "" && context.protocol == "openai.chat-text-sse.v1" && context.output_token_limit <= 4096 && context.message_count <= 64 && context.sequence < 4096 && ["protobuf","arrow"].contains(context.format) };`
	publication := v1.Publication{OperationID: "control-benchmark-activation", ExpectedRevision: &parent, Fence: 2, Policy: policy, Schema: f.schema}
	for i, family := range families {
		first := f.plan
		first.Family, first.Node, first.Revision, first.Fence = family, "node-0", 1, 2
		task := profileTask(t, first, *providerProfile())
		task.Budget = uint64(16 * nodes)
		plans := []v1.ProviderPlan{first}
		for j := 1; j < nodes; j++ {
			plan := first
			plan.Node = fmt.Sprintf("node-%d", j)
			digest, err := plan.Digest()
			if err != nil {
				t.Fatal(err)
			}
			task.Nodes = append(task.Nodes, plan.Node)
			task.BodyDigests[plan.Node] = task.BodyDigests[first.Node]
			task.StreamContracts[plan.Node] = digest
			task.NodeCostBounds[plan.Node] = 4
			plans = append(plans, plan)
		}
		bundle := config.Bundle{Governance: config.Governance{Schema: "agentic-ai-lab.loop-governor.v1", Family: family, OpenNodes: task.Nodes}, Tasks: []v1.Task{task}, Plans: plans, Publication: publication}
		if err := bundle.Validate(); err != nil {
			t.Fatal(err)
		}
		path := writeControlBundle(t, f, bundle, "json")
		owner := newControlProcess(t, f, path)
		owner.image = controlImage
		at := time.Now()
		owner.start(t)
		startupLog, err := os.ReadFile(filepath.Join(owner.directory, "control.log"))
		if err != nil || !strings.Contains(string(startupLog), "phase=bootstrap-source-channel-closed") {
			t.Fatal("static Go owner retained bootstrap source custody", err)
		}
		arm.activation = append(arm.activation, time.Since(at))
		arm.control[i] = owner
		arm.plans[i] = plans
	}
	if shared {
		ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
		defer cancel()
		for _, from := range families[1:] {
			view, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: families[0]})
			if err != nil {
				t.Fatal(err)
			}
			stamp := view.GetStamp()
			receipt, err := f.admin.RPC.MigrateExecutionDomains(f.admin.Context(ctx), &pb.DomainMigration{OperationId: "benchmark-union-" + from, BudgetFrom: from, BudgetTo: stamp.GetBudgetRoot(), HistoryFrom: from, HistoryTo: stamp.GetHistoryRoot(), BudgetFromEpoch: 1, BudgetToEpoch: stamp.GetBudgetEpoch(), HistoryFromEpoch: 1, HistoryToEpoch: stamp.GetHistoryEpoch()})
			if err != nil || !receipt.GetCommitted() {
				t.Fatal("benchmark shared domain binding", receipt, err)
			}
		}
	}
	return arm
}

func assertNoControlTrace(b *testing.B, arm *controlBenchArm) {
	b.Helper()
	log, err := os.ReadFile(filepath.Join(arm.f.directory, "server.log"))
	if err != nil {
		b.Fatal(err)
	}
	if strings.Contains(string(log), "weaver-provider-first-frame ") ||
		strings.Contains(string(log), "weaver-provider-scope ") {
		b.Fatal("light accounting arm emitted fine-grained Rust traces")
	}
}
func verifyControlBenchArm(t testing.TB, arm *controlBenchArm, shared bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	total := 0
	for _, plans := range arm.plans {
		for _, plan := range plans {
			receipt, err := arm.f.client.RPC.Inspect(arm.f.client.Context(ctx), &pb.OperationKey{Family: plan.Family, Node: plan.Node})
			digest, digestErr := plan.Digest()
			if err != nil || digestErr != nil || receipt.GetState() != "complete" || receipt.GetEvents() != 13 || receipt.GetDigest() != digest || receipt.GetReserved() != 4 || receipt.GetHeld() != uint64(4*len(plans)) || receipt.GetTarget() != "primary" {
				t.Fatal("control benchmark original receipt", receipt, err, digestErr)
			}
			total++
		}
		count := uint64(len(plans))
		if shared {
			count *= 4
		}
		view, err := arm.f.admin.RPC.InspectExecutionDomains(arm.f.admin.Context(ctx), &pb.OperationKey{Family: plans[0].Family})
		if err != nil || view.GetHeld() != 4*count || view.GetHistoryCount() != count {
			t.Fatal("control benchmark shared exposure", view, err)
		}
	}
	if arm.f.primary.Load() != int64(total) || arm.f.backup.Load() != 0 || arm.f.denied.Load() != 0 {
		t.Fatal("control benchmark duplicated/substituted provider invocation")
	}
}

func TestProviderGoControlMeasuredChain(t *testing.T) {
	// Exercise the same optimized WIF entrypoint as the paired benchmarks.
	image := wifImage(t, true)
	for _, shared := range []bool{false, true} {
		t.Run(fmt.Sprintf("shared=%t", shared), func(t *testing.T) {
			arm := newControlBenchArm(t, image, controlBinary, 2, shared, true, false, burstProviderSSE(13))
			for wave := range 2 {
				for owner := range 4 {
					ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
					started := providerObservationNanos()
					n, timing, err := readDomainProgramStreamTimed(ctx, arm.control[owner].client, arm.plans[owner][wave], pb.Encoding_ARROW_IPC, 4, nil, providerObservationNanos)
					plan := arm.plans[owner][wave]
					arm.frames = append(arm.frames, controlFrameSample{plan.Family, plan.Node, wave, started, timing.firstTick, timing.received, timing.frameGaps})
					cancel()
					if err != nil || n != 13 || timing.frames != 4 {
						t.Fatal("real Go routing / Rust streaming chain", n, timing, err)
					}
				}
			}
			verifyControlBenchArm(t, arm, shared)
			controlFrameLatencies(t, arm)
			first, gaps := controlArrivalLatencies(t, arm)
			controlFirstFramePhases(t, arm)
			if len(first) != 8 || len(gaps) != 24 {
				t.Fatal("incomplete arrival observations", len(first), len(gaps))
			}
			for _, owner := range arm.control {
				owner.stop(t)
			}
			arm.f.stop(t)
		})
	}
}

var controlFirstFramePhaseNames = [...]string{
	"front", "worker-wait", "worker-setup", "enqueue", "consume", "request-prepare",
	"dispatch-outside-transport", "broker-remainder", "upstream-transport", "headers-to-queue", "queue-to-client",
}

var controlTransportPhaseNames = [...]string{"connect", "tls", "write", "response-head"}

var controlLedgerPhaseNames = [...]string{
	"owner-gate-wait", "domain-wait", "transaction-begin", "domain-hold", "transaction-hold",
	"commit", "cedar", "publication-prepare", "original-prepare", "domain-prepare", "begin-poll", "begin-thread-cpu",
	"begin-sql-prepare", "begin-sql-prepare-cpu",
	"commit-poll", "commit-thread-cpu", "commit-sync",
}

const (
	controlBeginWall     = 2
	controlCommitWall    = 5
	controlDomainPrepare = 9
	controlBeginPollWall = len(controlLedgerPhaseNames) - 7
	controlBeginCPUWall  = len(controlLedgerPhaseNames) - 6
	controlPrepareWall   = len(controlLedgerPhaseNames) - 5
	controlPrepareCPU    = len(controlLedgerPhaseNames) - 4
	controlCommitPoll    = len(controlLedgerPhaseNames) - 3
	controlCommitCPU     = len(controlLedgerPhaseNames) - 2
	controlCommitSync    = len(controlLedgerPhaseNames) - 1
	controlBeginPolls    = len(controlLedgerPhaseNames)
	controlBeginPending  = controlBeginPolls + 1
	controlBeginCPUPolls = controlBeginPending + 1
	controlPrepareCalls  = controlBeginCPUPolls + 1
	controlPrepareCPUs   = controlPrepareCalls + 1
	controlCommitPolls   = controlPrepareCPUs + 1
	controlCommitPending = controlCommitPolls + 1
	controlCommitCPUs    = controlCommitPending + 1
	controlCommitSyncs   = controlCommitCPUs + 1
	controlLedgerFields  = controlCommitSyncs + 1
)

type controlFirstFrameRow struct {
	total     int64
	open      time.Duration
	reused    bool
	phases    [len(controlFirstFramePhaseNames)]int64
	transport [len(controlTransportPhaseNames)]int64
	ledger    [2][controlLedgerFields]int64
}

func reportDriverBegin(b *testing.B, rows []controlFirstFrameRow, stage int, label string) {
	b.Helper()
	var longest, longestOutside, cpuAtLongest, pollAtLongest time.Duration
	var polls, pending, slow, slowPending, slowCPUMajority int64
	begin := make([]time.Duration, 0, len(rows))
	cpu := make([]time.Duration, 0, len(rows))
	prepare, prepareCPU, restCPU := make([]time.Duration, 0, len(rows)), make([]time.Duration, 0, len(rows)), make([]time.Duration, 0, len(rows))
	for _, row := range rows {
		sample := row.ledger[stage]
		wall := time.Duration(sample[controlBeginWall])
		poll, active := time.Duration(sample[controlBeginPollWall]), time.Duration(sample[controlBeginCPUWall])
		if wall > longest {
			longest, cpuAtLongest, pollAtLongest = wall, active, poll
		}
		longestOutside = max(longestOutside, wall-poll)
		begin = append(begin, wall)
		prepare = append(prepare, time.Duration(sample[controlPrepareWall]))
		if sample[controlBeginCPUPolls] != 0 {
			cpu = append(cpu, active)
			prepareCPU = append(prepareCPU, time.Duration(sample[controlPrepareCPU]))
			restCPU = append(restCPU, max(0, active-time.Duration(sample[controlPrepareCPU])))
		}
		polls += sample[controlBeginPolls]
		pending += sample[controlBeginPending]
		if wall >= time.Millisecond {
			slow++
			if sample[controlBeginPending] != 0 {
				slowPending++
			}
			if active >= poll/2 {
				slowCPUMajority++
			}
		}
	}
	b.ReportMetric(tailMillis(begin, 99), label+"-begin-p99-ms")
	b.ReportMetric(millis(longest), label+"-begin-max-ms")
	b.ReportMetric(millis(longestOutside), label+"-begin-outside-poll-max-ms")
	b.ReportMetric(float64(polls), label+"-begin-polls")
	b.ReportMetric(float64(pending), label+"-begin-pending")
	b.ReportMetric(float64(slow), label+"-begin-ge1ms")
	b.ReportMetric(float64(slowPending), label+"-begin-ge1ms-with-pending")
	b.ReportMetric(tailMillis(prepare, 50), label+"-begin-sql-prepare-p50-ms")
	if len(cpu) != 0 {
		b.ReportMetric(float64(len(cpu)), label+"-begin-cpu-samples")
		b.ReportMetric(tailMillis(cpu, 50), label+"-begin-cpu-p50-ms")
		b.ReportMetric(millis(cpuAtLongest), label+"-begin-cpu-at-max-wall-ms")
		b.ReportMetric(millis(pollAtLongest), label+"-begin-poll-at-max-wall-ms")
		b.ReportMetric(float64(slowCPUMajority), label+"-begin-ge1ms-cpu-majority")
		b.ReportMetric(tailMillis(prepareCPU, 50), label+"-begin-sql-prepare-cpu-p50-ms")
		b.ReportMetric(tailMillis(restCPU, 50), label+"-begin-rest-poll-cpu-p50-ms")
	}
}

func reportDriverCommit(b *testing.B, rows []controlFirstFrameRow, stage int, label string) {
	b.Helper()
	commits := make([]time.Duration, 0, len(rows))
	var longest [controlLedgerFields]int64
	var pending, syncs int64
	for _, row := range rows {
		sample := row.ledger[stage]
		commits = append(commits, time.Duration(sample[controlCommitWall]))
		pending += sample[controlCommitPending]
		syncs += sample[controlCommitSyncs]
		if sample[controlCommitWall] > longest[controlCommitWall] {
			longest = sample
		}
	}
	b.ReportMetric(tailMillis(commits, 99), label+"-commit-p99-ms")
	b.ReportMetric(millis(time.Duration(longest[controlCommitWall])), label+"-commit-max-ms")
	b.ReportMetric(millis(time.Duration(longest[controlCommitPoll])), label+"-commit-max-poll-ms")
	b.ReportMetric(millis(time.Duration(longest[controlCommitCPU])), label+"-commit-max-thread-cpu-ms")
	b.ReportMetric(millis(time.Duration(longest[controlCommitSync])), label+"-commit-max-sync-ms")
	b.ReportMetric(float64(longest[controlCommitPending]), label+"-commit-max-pending")
	b.ReportMetric(float64(pending), label+"-commit-pending")
	b.ReportMetric(float64(syncs), label+"-commit-sync-count")
}

func reportControlFirstFrame(b *testing.B, arm *controlBenchArm, label string) {
	b.Helper()
	rows := controlFirstFramePhases(b, arm)
	enqueue := make([]time.Duration, 0, len(rows))
	open := make([]time.Duration, 0, len(rows))
	domainWait := make([]time.Duration, 0, len(rows))
	domainHold := make([]time.Duration, 0, len(rows))
	domainPrepare := make([]time.Duration, 0, len(rows))
	var reused int
	for _, row := range rows {
		enqueue = append(enqueue, time.Duration(row.phases[3]))
		open = append(open, row.open)
		if row.reused {
			reused++
		}
		domainWait = append(domainWait, time.Duration(row.ledger[0][1]))
		domainHold = append(domainHold, time.Duration(row.ledger[0][3]))
		domainPrepare = append(domainPrepare, time.Duration(row.ledger[0][controlDomainPrepare]))
	}
	if label != "reuse" && reused != 0 {
		b.Fatal("unexpected connection reuse in the reference arm")
	}
	b.ReportMetric(float64(reused)/float64(len(rows)), label+"-reused-fraction")
	b.ReportMetric(tailMillis(domainWait, 95), label+"-enqueue-domain-wait-p95-ms")
	b.ReportMetric(tailMillis(domainHold, 50), label+"-enqueue-domain-hold-p50-ms")
	b.ReportMetric(tailMillis(domainHold, 99), label+"-enqueue-domain-hold-p99-ms")
	b.ReportMetric(tailMillis(domainPrepare, 50), label+"-enqueue-domain-prepare-p50-ms")
	b.ReportMetric(tailMillis(open, 50), label+"-ledger-open-p50-ms")
	b.ReportMetric(tailMillis(open, 99), label+"-ledger-open-p99-ms")
	b.ReportMetric(tailMillis(enqueue, 50), label+"-enqueue-p50-ms/stream")
	b.ReportMetric(tailMillis(enqueue, 99), label+"-enqueue-p99-ms/stream")
	// Attribute the observed P99 stream as a whole. Independently ranked phase
	// percentiles cannot be added or subtracted to explain this stream.
	slices.SortFunc(rows, func(a, b controlFirstFrameRow) int {
		return cmp.Compare(a.total, b.total)
	})
	tail := rows[tailRank(len(rows), 99)]
	for i, name := range controlFirstFramePhaseNames {
		b.ReportMetric(millis(time.Duration(tail.phases[i])), label+"-first-frame-p99-"+name+"-ms")
	}
	for i, name := range controlTransportPhaseNames {
		b.ReportMetric(millis(time.Duration(tail.transport[i])), label+"-first-frame-p99-upstream-"+name+"-ms")
	}
	// Ledger counters overlap inside each outer stage.
	for stage, name := range []string{"enqueue", "consume"} {
		reportDriverBegin(b, rows, stage, label+"-"+name)
		reportDriverCommit(b, rows, stage, label+"-"+name)
		for i, phase := range controlLedgerPhaseNames {
			b.ReportMetric(millis(time.Duration(tail.ledger[stage][i])), label+"-first-frame-p99-"+name+"-"+phase+"-ms")
		}
	}
	if os.Getenv("WEAVER_TEST_PROVIDER_SCOPE_TIMELINE") != "" {
		log, err := os.ReadFile(filepath.Join(arm.f.directory, "server.log"))
		if err != nil {
			b.Fatal(err)
		}
		for _, line := range strings.Split(string(log), "\n") {
			if strings.HasPrefix(line, "weaver-provider-scope ") ||
				strings.HasPrefix(line, "weaver-provider-scope-timeline ") {
				b.Log(label, line)
			}
		}
	}
}

func controlFirstFramePhases(t testing.TB, arm *controlBenchArm) []controlFirstFrameRow {
	t.Helper()
	log, err := os.ReadFile(filepath.Join(arm.f.directory, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	const transportOffset = 13
	const timingFields = transportOffset + len(controlTransportPhaseNames)
	brokerTimes := make(map[[2]string][timingFields + 2*controlLedgerFields]int64)
	for _, line := range strings.Split(string(log), "\n") {
		raw, ok := strings.CutPrefix(line, "weaver-provider-first-frame ")
		if !ok {
			continue
		}
		fields := strings.Fields(raw)
		if len(fields) != 2+timingFields+2*controlLedgerFields {
			t.Fatalf("invalid first-frame observation: %q", raw)
		}
		key := [2]string{fields[0], fields[1]}
		if _, exists := brokerTimes[key]; exists {
			t.Fatalf("duplicate first-frame observation: %v", key)
		}
		var values [timingFields + 2*controlLedgerFields]int64
		for i, value := range fields[2:] {
			nanos, err := strconv.ParseInt(value, 10, 64)
			if err != nil || nanos < 0 {
				t.Fatalf("invalid first-frame timing: %q", value)
			}
			values[i] = nanos
		}
		brokerTimes[key] = values
	}
	rows := make([]controlFirstFrameRow, 0, len(arm.frames))
	for _, stream := range arm.frames {
		key := [2]string{stream.family, stream.node}
		times, ok := brokerTimes[key]
		first, received := stream.first, stream.first != 0
		submitted, workerWait, workerSetup, headers, queued, transport := times[0], times[1], times[2], times[3], times[4], times[5]
		enqueue, consume, prepare, dispatch, writeTransport := times[6], times[7], times[8], times[9], times[10]
		if !ok || !received {
			t.Fatalf("missing first-frame observation for %v: server=%t client=%t", key, ok, received)
		}
		if submitted < stream.started || headers < submitted ||
			headers-submitted < workerWait || headers-submitted-workerWait < workerSetup ||
			headers-submitted-workerWait-workerSetup < transport || queued < headers || first < queued ||
			dispatch < writeTransport || transport < writeTransport {
			t.Fatalf("unjoinable first-frame observation for %v: started=%d received=%d trace=%v",
				key, stream.started, first, times)
		}
		outsideTransport := headers - submitted - workerWait - workerSetup - transport
		dispatchOutsideTransport := dispatch - writeTransport
		for _, phase := range [...]int64{enqueue, consume, prepare, dispatchOutsideTransport} {
			if phase > outsideTransport {
				t.Fatalf("overlapping broker phase observation for %v: phase %d exceeds remaining %d ns (broker timings %v)", key, phase, outsideTransport, times)
			}
			outsideTransport -= phase
		}
		if times[12] > 1 {
			t.Fatalf("invalid connection reuse observation for %v", key)
		}
		upstream := [len(controlTransportPhaseNames)]int64(times[transportOffset:timingFields])
		connect, tls, write, head := upstream[0], upstream[1], upstream[2], upstream[3]
		if connect > writeTransport || tls > writeTransport-connect ||
			write != writeTransport-connect-tls || head != transport-writeTransport {
			t.Fatalf("unjoinable upstream transport stages for %v: %v", key, upstream)
		}
		row := controlFirstFrameRow{total: first - stream.started, open: time.Duration(times[11]), reused: times[12] == 1, phases: [...]int64{
			submitted - stream.started, workerWait, workerSetup, enqueue, consume, prepare,
			dispatchOutsideTransport, outsideTransport, transport, queued - headers, first - queued,
		}, transport: upstream}
		for stage := range row.ledger {
			start := timingFields + stage*controlLedgerFields
			sample := &row.ledger[stage]
			copy(sample[:], times[start:start+controlLedgerFields])
			if sample[controlBeginPolls] != sample[controlBeginPending]+1 ||
				sample[controlBeginPollWall] > sample[controlBeginWall] ||
				sample[controlPrepareCalls] != 1 || sample[controlPrepareWall] > sample[controlBeginPollWall] {
				t.Fatalf("unjoinable transaction begin for %v stage %d: %v", key, stage, *sample)
			}
			if sample[controlCommitPolls] != sample[controlCommitPending]+1 ||
				sample[controlCommitPoll] > sample[controlCommitWall] || sample[controlCommitSync] > sample[controlCommitPoll] {
				t.Fatalf("unjoinable transaction commit for %v stage %d: %v", key, stage, *sample)
			}
			if (runtime.GOOS == "darwin" || runtime.GOOS == "linux") &&
				(sample[controlBeginCPUPolls] != sample[controlBeginPolls] ||
					sample[controlPrepareCPUs] != sample[controlPrepareCalls] ||
					sample[controlCommitCPUs] != sample[controlCommitPolls]) {
				t.Fatalf("missing transaction thread CPU for %v stage %d: %v", key, stage, *sample)
			}
		}
		rows = append(rows, row)
		delete(brokerTimes, key)
	}
	if len(brokerTimes) != 0 {
		t.Fatal("unexpected broker first-frame observations")
	}
	return rows
}

func controlArrivalLatencies(t testing.TB, arm *controlBenchArm) (first, gaps []time.Duration) {
	t.Helper()
	for _, stream := range arm.frames {
		firstAt := stream.first
		if firstAt == 0 || firstAt < stream.started {
			t.Fatal("invalid request to first-frame observation")
		}
		first = append(first, time.Duration(firstAt-stream.started))
		if len(stream.frameGaps) != len(stream.received)-1 {
			t.Fatal("missing client inter-frame observation")
		}
		for _, gap := range stream.frameGaps {
			if gap < 0 {
				t.Fatal("client receive clock moved backward")
			}
			gaps = append(gaps, gap)
		}
	}
	return first, gaps
}

func controlFrameLatencies(t testing.TB, arm *controlBenchArm) []time.Duration {
	t.Helper()
	groups := providerHandoffGroups(t, arm.f)
	if len(groups) != len(arm.plans) {
		t.Fatal("missing broker handoff family")
	}
	total := 0
	for _, plans := range arm.plans {
		if len(groups[plans[0].Family]) != len(plans) {
			t.Fatal("missing or duplicate broker handoff group")
		}
		total += len(plans)
	}
	if len(arm.frames) != total {
		t.Fatal("missing received stream observation")
	}
	var latencies []time.Duration
	seen := map[string]map[int]bool{}
	for _, stream := range arm.frames {
		rows := groups[stream.family]
		if stream.wave < 0 || stream.wave >= len(rows) {
			t.Fatal("foreign handoff ordinal")
		}
		if seen[stream.family] == nil {
			seen[stream.family] = map[int]bool{}
		}
		if seen[stream.family][stream.wave] {
			t.Fatal("duplicate received stream")
		}
		seen[stream.family][stream.wave] = true
		stamps := rows[stream.wave]
		if len(stamps) != len(stream.received) {
			t.Fatal("missing broker or client frame")
		}
		for sequence, received := range stream.received {
			staged, ok := stamps[sequence]
			if !ok || received < staged {
				t.Fatal("unjoinable broker queue to client observation")
			}
			latencies = append(latencies, time.Duration(received-staged))
		}
	}
	return latencies
}
