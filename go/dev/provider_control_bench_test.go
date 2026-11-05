// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
)

type controlFrameSample struct {
	family   string
	wave     int
	received map[uint64]int64
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

// Four independently bootstrapped task owners each expose 32 distinct original
// nodes. Both arms activate through Go; only the measured request path differs.
// Cold activation stays separate from the 128 warm, exactly-once operations.
func BenchmarkProviderGoControlPair(b *testing.B) {
	image := wifImage(b, true)
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
					arms[i] = newControlBenchArm(b, image, 32*b.N, shared)
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
							err       error
						}
						results := make(chan result, 4)
						start := make(chan struct{})
						for owner := range 4 {
							go func() {
								client := arm.f.client
								if i == 1 {
									client = arm.control[owner].client
								}
								ctx, cancel := context.WithTimeout(b.Context(), 12*time.Second)
								defer cancel()
								<-start
								at := time.Now()
								n, timing, err := readDomainProgramStreamWithClient(ctx, client, arm.plans[owner][wave], encoding, rows)
								results <- result{owner, n, timing, time.Since(at), err}
							}()
						}
						close(start)
						for range 4 {
							r := <-results
							if r.err != nil || r.events != 13 || r.transport.frames != (13+int(rows)-1)/int(rows) {
								b.Fatalf("control stream completion: %+v", r)
							}
							arm.frames = append(arm.frames, controlFrameSample{arm.plans[r.owner][wave].Family, wave, r.transport.received})
							arm.latency = append(arm.latency, r.latency)
							arm.recv = append(arm.recv, r.transport.recv)
							arm.decode = append(arm.decode, r.transport.decode)
						}
						arm.wall += time.Since(began)
					}
				}
				b.StopTimer()
				b.ReportMetric(0, "ns/op")
				for i, label := range []string{"direct-rust", "go-control"} {
					arm := arms[i]
					verifyControlBenchArm(b, arm, shared)
					b.ReportMetric(float64(len(arm.latency))/arm.wall.Seconds(), label+"-complete/s")
					b.ReportMetric(tailMillis(arm.latency, 99), label+"-stream-p99-ms")
					b.ReportMetric(tailMillis(controlFrameLatencies(b, arm), 99), label+"-rust-queue-to-client-p99-ms/frame")
					b.ReportMetric(tailMillis(arm.recv, 99), label+"-grpc-recv-p99-ms/stream")
					b.ReportMetric(tailMillis(arm.decode, 99), label+"-decode-p99-ms/stream")
					for j, duration := range arm.activation {
						b.ReportMetric(float64(duration.Nanoseconds())/1e6, fmt.Sprintf("%s-cold-owner%d-ms", label, j))
					}
					for _, owner := range arm.control {
						owner.stop(b)
					}
					arm.f.stop(b)
				}
			})
		}
	}
}

func newControlBenchArm(t testing.TB, image string, nodes int, shared bool) *controlBenchArm {
	t.Helper()
	if nodes > 64 {
		t.Fatal("frozen control benchmark supports at most 64 nodes per task; use -benchtime=1x")
	}
	f := providerFixture(t, burstProviderSSE(13), false, image, []string{"--exact", "grpc_config::serve_wif_gateway", "--ignored", "--nocapture"}, []string{"WEAVER_STORAGE_JOURNAL=mvcc", "WEAVER_TEST_PROVIDER_SCOPE_TRACE=1"}, providerProfile(), nil, nil)
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
	image := filepath.Join(t.TempDir(), "weaver-control-chain")
	if _, err := publishProviderImage(observedServer(t), image); err != nil {
		t.Fatal(err)
	}
	for _, shared := range []bool{false, true} {
		t.Run(fmt.Sprintf("shared=%t", shared), func(t *testing.T) {
			arm := newControlBenchArm(t, image, 2, shared)
			for wave := range 2 {
				for owner := range 4 {
					ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
					n, timing, err := readDomainProgramStreamWithClient(ctx, arm.control[owner].client, arm.plans[owner][wave], pb.Encoding_ARROW_IPC, 4)
					arm.frames = append(arm.frames, controlFrameSample{arm.plans[owner][wave].Family, wave, timing.received})
					cancel()
					if err != nil || n != 13 || timing.frames != 4 {
						t.Fatal("real Go routing / Rust streaming chain", n, timing, err)
					}
				}
			}
			verifyControlBenchArm(t, arm, shared)
			controlFrameLatencies(t, arm)
			for _, owner := range arm.control {
				owner.stop(t)
			}
			arm.f.stop(t)
		})
	}
}

func controlFrameLatencies(t testing.TB, arm *controlBenchArm) []time.Duration {
	t.Helper()
	groups := providerHandoffGroups(t, arm.f)
	if len(groups) != len(arm.plans) {
		t.Fatal("missing native handoff family")
	}
	total := 0
	for _, plans := range arm.plans {
		if len(groups[plans[0].Family]) != len(plans) {
			t.Fatal("missing or duplicate native handoff group")
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
			t.Fatal("missing native or client frame")
		}
		for sequence, received := range stream.received {
			staged, ok := stamps[sequence]
			if !ok || received < staged {
				t.Fatal("unjoinable native queue to client observation")
			}
			latencies = append(latencies, time.Duration(received-staged))
		}
	}
	return latencies
}
