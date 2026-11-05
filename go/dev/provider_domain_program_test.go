// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
)

// Use one image and alternate which owner runs first in each paired wave.
// Fixtures have distinct MVCC files and run authenticated gRPC and real TLS SSE.
func BenchmarkProviderDomainProgram(b *testing.B) {
	image := wifImage(b, true)
	for _, ranges := range []int{5, 13} {
		for _, parallel := range []int{1, 4} {
			for _, shared := range []bool{false, true} {
				name := fmt.Sprintf("ranges=%d/concurrent=%d/shared=%t", ranges, parallel, shared)
				b.Run(name, func(b *testing.B) {
					benchmarkDomainPrograms(b, image, ranges, parallel, shared)
				})
			}
		}
	}
}

func benchmarkDomainPrograms(b *testing.B, image string, ranges, parallel int, shared bool) {
	b.Helper()
	b.StopTimer()
	handler := func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		for range ranges - 3 {
			emitChunk(w, "delta", false)
		}
		emitChunk(w, "", true)
		fmt.Fprint(w, "data: {\"id\":\"stream-1\",\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[],\"usage\":{\"total_tokens\":7}}\n\ndata: [DONE]\n\n")
	}
	const samples = 128
	var arms [2]struct {
		fixture *fixture
		latency []time.Duration
		wall    time.Duration
	}
	for i, name := range []string{"fresh", "cached"} {
		env := []string{"WEAVER_STORAGE_JOURNAL=mvcc", "WEAVER_TEST_PROVIDER_TIMINGS=1", "WEAVER_TEST_CACHE_CURRENTNESS_PLANS=0", "WEAVER_TEST_LOCKED_PUBLICATION_REVIEW=0", "WEAVER_TEST_LOCKED_ORIGINAL_EVIDENCE=0", "WEAVER_TEST_FRESH_PROVIDER_DOMAIN_PLAN=0"}
		if name == "fresh" {
			env = append(env, "WEAVER_TEST_FRESH_PROVIDER_DOMAIN_PLAN=1")
		}
		args := []string{"--exact", "grpc_config::serve_wif_gateway", "--ignored", "--nocapture"}
		f := providerFixture(b, handler, false, image, args, env, providerProfile(), nil, nil)
		ctx, cancel := context.WithTimeout(b.Context(), 5*time.Second)
		parent := uint64(0)
		policy := strings.Replace(f.policy, `context.family == "f"`, `context.family != "f"`, 1)
		receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{
			OperationId: "domain-program-benchmark", ExpectedRevision: &parent, Fence: 2, Policy: policy, Schema: f.schema,
		})
		cancel()
		if err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
			b.Fatalf("benchmark policy %v %v", receipt, err)
		}
		arms[i].fixture = f
	}
	b.StartTimer()
	for wave := range b.N * samples / parallel {
		for _, i := range []int{wave % 2, 1 - wave%2} {
			arm := &arms[i]
			plans := registerDomainProgramWave(b, arm.fixture, wave, parallel, shared)
			latency, wall := measureDomainProgramWave(b, arm.fixture, plans, ranges, shared)
			arm.latency = append(arm.latency, latency...)
			arm.wall += wall
		}
	}
	b.StopTimer()
	b.ReportMetric(0, "ns/op")
	for i, name := range []string{"fresh", "cached"} {
		arm := &arms[i]
		total := len(arm.latency)
		if arm.fixture.primary.Load() != int64(total) || arm.fixture.backup.Load() != 0 || arm.fixture.denied.Load() != 0 {
			b.Fatalf("%s had substituted or duplicate sends", name)
		}
		timing, domainReads := providerTimingSamples(b, arm.fixture, total)
		slices.Sort(domainReads)
		b.ReportMetric(float64(domainReads[(95*total+99)/100-1])/1e6, name+"-domain-p95-ms")
		b.ReportMetric(float64(domainReads[(99*total+99)/100-1])/1e6, name+"-domain-p99-ms")
		for j, label := range providerTimingLabels {
			if label == "domain-scopes" && timing[j] != uint64(total*(5+2*ranges)) {
				b.Fatalf("%s measured %d decision scopes for %d streams and %d ranges", name, timing[j], total, ranges)
			}
			if label == "domain-read" || label == "domain-prepare" || label == "domain-wait" || label == "txn-begin" || label == "commit" {
				b.ReportMetric(float64(timing[j])/float64(total)/1e6, name+"-"+label+"-ms/stream")
			}
		}
		slices.Sort(arm.latency)
		b.ReportMetric(float64(arm.latency[(95*total+99)/100-1])/1e6, name+"-p95-ms")
		b.ReportMetric(float64(arm.latency[(99*total+99)/100-1])/1e6, name+"-p99-ms")
		b.ReportMetric(float64(total)/arm.wall.Seconds(), name+"-complete/s")
		b.ReportMetric(float64(total), name+"-completed")
		arm.fixture.stop(b)
	}
}

func registerDomainProgramWave(b *testing.B, f *fixture, wave, parallel int, shared bool) []v1.ProviderPlan {
	b.Helper()
	ctx, cancel := context.WithTimeout(b.Context(), 5*time.Second)
	defer cancel()
	plans := make([]v1.ProviderPlan, parallel)
	for i := range plans {
		plan := f.plan
		plan.Family, plan.Revision, plan.Fence = fmt.Sprintf("domain-%d-%d", wave, i), 1, 2
		root, limit := plan.Family, uint64(4)
		if shared {
			root, limit = fmt.Sprintf("shared-%d", wave), uint64(4*parallel)
		}
		task := profileTask(b, plan, *providerProfile())
		_, err := f.admin.RPC.RegisterOriginalTask(f.admin.Context(ctx), &pb.RegisterOriginalTaskRequest{
			Task: gatewayclient.Task(task), Domains: &pb.DomainBinding{Origin: plan.Family, Budget: root, History: root, BudgetLimit: limit},
			Admission: &pb.TaskAdmission{TaskKey: plan.Family, OperationId: "register-" + plan.Family},
		})
		if err != nil {
			b.Fatalf("register benchmark original %s: %v", plan.Family, err)
		}
		plans[i] = plan
	}
	return plans
}

func measureDomainProgramWave(b *testing.B, f *fixture, plans []v1.ProviderPlan, ranges int, shared bool) ([]time.Duration, time.Duration) {
	b.Helper()
	ctx, cancel := context.WithTimeout(b.Context(), 12*time.Second)
	defer cancel()
	type result struct {
		latency time.Duration
		events  int
		err     error
	}
	ready, start := make(chan struct{}, len(plans)), make(chan struct{})
	results := make(chan result, len(plans))
	for _, plan := range plans {
		go func() {
			ready <- struct{}{}
			<-start
			began := time.Now()
			var r result
			r.events, r.err = readDomainProgramStream(ctx, f, plan)
			r.latency = time.Since(began)
			results <- r
		}()
	}
	for range plans {
		<-ready
	}
	began := time.Now()
	close(start)
	latencies := make([]time.Duration, 0, len(plans))
	for range plans {
		r := <-results
		if r.err != nil || r.events != ranges {
			b.Fatalf("invalid stream completion with %d events: %v", r.events, r.err)
		}
		latencies = append(latencies, r.latency)
	}
	wall := time.Since(began)
	// Inspect uses its own bounded observation lane. Verify all receipts
	// sequentially after the timed stream calls have reached EOF.
	for _, plan := range plans {
		digest, err := plan.Digest()
		if err != nil {
			b.Fatal(err)
		}
		receipt, err := f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: plan.Family, Node: plan.Node})
		if err != nil || receipt.GetState() != "complete" || receipt.GetEvents() != uint64(ranges) ||
			receipt.GetTarget() != "primary" || receipt.GetDigest() != digest || receipt.GetReserved() != plan.Ceiling {
			b.Fatalf("benchmark receipt mismatch: %v %v", receipt, err)
		}
		count := uint64(1)
		if shared {
			count = uint64(len(plans))
		}
		view, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: plan.Family})
		if err != nil || view.GetHeld() != count*plan.Ceiling || view.GetHistoryCount() != count {
			b.Fatalf("benchmark hold/history mismatch: %v %v", view, err)
		}
	}
	return latencies, wall
}

func readDomainProgramStream(ctx context.Context, f *fixture, plan v1.ProviderPlan) (int, error) {
	stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{
		Plan: gatewayclient.Plan(plan), Encoding: pb.Encoding_PROTOBUF, BatchRows: 1,
	})
	if err != nil {
		return 0, err
	}
	next, done := 0, false
	for {
		frame, err := stream.Recv()
		if err == io.EOF && done {
			return next, nil
		}
		if err != nil {
			return next, err
		}
		events, err := gatewayclient.Events(frame, pb.Encoding_PROTOBUF)
		if err != nil {
			return next, err
		}
		if len(events) != 1 || done || events[0].GetSequence() != uint64(next) ||
			frame.GetTarget() != "primary" || frame.GetModel() != plan.Model {
			return next, fmt.Errorf("invalid benchmark frame at %d", next)
		}
		done = events[0].GetKind() == "done"
		next++
	}
}
