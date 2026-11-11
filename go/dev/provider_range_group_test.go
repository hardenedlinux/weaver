// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"fmt"
	"net/http"
	"runtime"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
)

const providerUsageAndDone = "data: {\"id\":\"stream-1\",\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[],\"usage\":{\"total_tokens\":7}}\n\ndata: [DONE]\n\n"

func burstProviderSSE(events int) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		var burst strings.Builder
		for range events - 3 {
			writeProviderChunk(&burst, "delta", false)
		}
		writeProviderChunk(&burst, "", true)
		burst.WriteString(providerUsageAndDone)
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, burst.String())
	}
}

func TestProviderGroupedRangeCommitRecovery(t *testing.T) {
	for _, mode := range []string{"rollback", "crash-before", "lost-ack", "crash-after", "revoke-after"} {
		t.Run(mode, func(t *testing.T) {
			const group = 4
			before := mode == "rollback" || mode == "crash-before"
			cut, phase, marker := "prepare-after", "AfterRangePrepareCommit", group
			if before {
				cut, phase, marker = "prepare-before", "BeforeRangePrepareCommit", 0
			}
			controller := observeCommit(t)
			f := fixtureWithInvocation(t, burstProviderSSE(5), false, observedServer(t),
				[]string{"--exact", "provider_commit_tests::serve_observed_gateway", "--ignored", "--nocapture"},
				[]string{"WEAVER_STORAGE_JOURNAL=mvcc", "WEAVER_TEST_COMMIT_SOCKET=" + controller.path, "WEAVER_TEST_COMMIT_CUT=" + cut})
			ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
			defer cancel()
			controller.await(t, ctx, "Boot", 0)
			type result struct {
				events int
				err    error
			}
			done := make(chan result, 1)
			go func() {
				n := 0
				_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { n++; return nil })
				done <- result{n, err}
			}()
			event := controller.await(t, ctx, phase, marker)
			switch mode {
			case "crash-before", "crash-after":
				if err := f.child.Process.Kill(); err != nil {
					t.Fatal(err)
				}
				select {
				case err := <-f.exited:
					if err == nil {
						t.Fatal("expected process crash")
					}
				case <-ctx.Done():
					t.Fatal("crashed process did not exit")
				}
				f.child = nil
				f.client.Connection.Close()
				f.admin.Connection.Close()
				event.socket.Close()
			case "rollback":
				resumeCommit(t, event, 'r')
			case "lost-ack":
				resumeCommit(t, event, 'l')
			case "revoke-after":
				revision := uint64(0)
				receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{
					OperationId: "revoke-prepared-group", ExpectedRevision: &revision, Fence: 2,
					Policy: "forbid(principal,action,resource);", Schema: f.schema,
				})
				if err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
					t.Fatalf("revoke before range enqueue: %v %v", receipt, err)
				}
				resumeCommit(t, event, 'c')
			}
			select {
			case result := <-done:
				if result.err == nil || result.events != 0 {
					t.Fatalf("unconfirmed or revoked group emitted frames: %+v", result)
				}
			case <-ctx.Done():
				t.Fatal("original RPC did not finish", ctx.Err())
			}
			assertNoFaultWorkerUnwind(t, f)
			if f.child != nil {
				f.stop(t)
			}
			f.start(t)
			controller.await(t, ctx, "Boot", marker)
			receipt := inspect(t, f)
			if receipt.State != "unknown" || receipt.Events != uint64(marker) || receipt.Held != 4 {
				t.Fatalf("recovered incomplete or released reservation: %v", receipt)
			}
			originalStillSpent(t, f, receipt)
		})
	}
}

func BenchmarkProviderRangePreparationGroup(b *testing.B) {
	image := wifImage(b, true)
	for _, cohort := range []struct {
		name          string
		paced, loaded bool
	}{{"burst", false, false}, {"paced", true, false}, {"burst-loaded", false, true}} {
		b.Run(cohort.name, func(b *testing.B) {
			benchmarkRangePreparationGroup(b, image, cohort.paced, cohort.loaded)
		})
	}
}

func benchmarkRangePreparationGroup(b *testing.B, image string, paced, loaded bool) {
	b.Helper()
	b.StopTimer()
	const ranges, parallel, samples = 13, 4, 128
	var arms [2]providerTailArm
	for i := range arms {
		env := []string{"WEAVER_STORAGE_JOURNAL=mvcc", "WEAVER_TEST_PROVIDER_TAIL=1", "WEAVER_TEST_PROVIDER_SCOPE_TRACE=1", "WEAVER_TEST_SINGLE_RANGE_COMMIT=1"}
		if i == 0 {
			env = append(env, "WEAVER_TEST_SINGLE_RANGE_PREPARE=1")
		}
		handler := burstProviderSSE(ranges)
		if paced {
			handler = domainBenchmarkSSE(ranges)
		}
		arms[i].fixture = domainBenchmarkFixture(b, image, env, handler)
	}
	var stopPressure func() (time.Duration, time.Duration)
	if loaded {
		stopPressure = startProviderPressure(b, max(1, runtime.NumCPU()/2))
	}
	b.StartTimer()
	for wave := range b.N * samples / parallel {
		for _, i := range []int{wave % 2, 1 - wave%2} {
			arm := &arms[i]
			plans := registerDomainProgramWave(b, arm.fixture, wave, parallel, true)
			streams, wall := measureDomainProgramWave(b, arm.fixture, plans, ranges, true)
			arm.streams = append(arm.streams, streams...)
			arm.wall += wall
		}
	}
	b.StopTimer()
	if stopPressure != nil {
		cpu, wall := stopPressure()
		b.ReportMetric(cpu.Seconds()/wall.Seconds(), "pressure-cpu-equivalents")
	}
	b.ReportMetric(0, "ns/op")
	for i, mode := range []string{"single", "group"} {
		arm := &arms[i]
		reportProviderTailArm(b, arm, mode)
		prepares := ranges
		if i == 1 {
			prepares = (ranges + 3) / 4
			if paced {
				prepares = 0 // Measure the opportunistic window without assuming TLS chunk alignment.
			}
		}
		reportScheduledEncoding(b, arm, mode, ranges, prepares, ranges, true)
		arm.fixture.stop(b)
	}
}
