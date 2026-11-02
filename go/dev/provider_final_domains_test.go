//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
)

func independentProviderPlans(t *testing.T, f *fixture) []v1.ProviderPlan {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	revision := uint64(0)
	policy := strings.Replace(f.policy, `context.family == "f"`, `["left", "right"].contains(context.family)`, 1)
	receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "independent-domains", ExpectedRevision: &revision, Fence: 2, Policy: policy, Schema: f.schema})
	if err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatalf("publish domains: %v %v", receipt, err)
	}
	var plans []v1.ProviderPlan
	for _, family := range []string{"left", "right"} {
		plan := f.plan
		plan.Family = family
		plan.Revision = 1
		plan.Fence = 2
		digest, err := plan.Digest()
		if err != nil {
			t.Fatal(err)
		}
		body := sha256.Sum256([]byte(plan.Body))
		endpoints := map[string]string{}
		var targets []string
		for _, route := range plan.Routes {
			endpoints[route.Target] = route.Endpoint
			targets = append(targets, route.Target)
		}
		task := v1.Task{ProviderProfile: providerProfile(), Family: family, Principal: "alice", Profile: "p", Nodes: []string{"infer"}, Targets: targets, Endpoints: endpoints, BodyDigests: map[string]string{"infer": hex.EncodeToString(body[:])}, NodeCostBounds: map[string]uint64{"infer": 4}, StreamContracts: map[string]string{"infer": digest}, Models: []string{"model-a"}, Budget: 8}
		if _, err := f.admin.RPC.RegisterTask(f.admin.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(task)}); err != nil {
			t.Fatal(err)
		}
		plans = append(plans, plan)
	}
	return plans
}

func TestProviderMVCCIndependentFinalSendsAndRevocation(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	for _, revoke := range []bool{false, true} {
		t.Run(map[bool]string{false: "overlapping-send", true: "revoke-all-live-domains"}[revoke], func(t *testing.T) {
			entered := make(chan struct{}, 2)
			headers := make(chan struct{})
			tail := make(chan struct{})
			var releaseHeaders, releaseTail sync.Once
			f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
				entered <- struct{}{}
				<-headers
				w.Header().Set("Content-Type", "text/event-stream")
				w.WriteHeader(200)
				w.(http.Flusher).Flush()
				<-tail
				completeSSE(w, r)
			}, false)
			t.Cleanup(func() { releaseHeaders.Do(func() { close(headers) }); releaseTail.Do(func() { close(tail) }) })
			plans := independentProviderPlans(t, f)
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			done := make(chan error, 2)
			for _, plan := range plans {
				go func() {
					_, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
					done <- err
				}()
			}
			for range 2 {
				select {
				case <-entered:
				case err := <-done:
					t.Fatalf("request ended before both handlers overlapped: %v", err)
				case <-ctx.Done():
					t.Fatal("independent sends serialized before response headers")
				}
			}
			published := make(chan error, 1)
			if revoke {
				go func() {
					revision := uint64(1)
					r, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "revoke-live-domains", ExpectedRevision: &revision, Fence: 3, Policy: "forbid(principal,action,resource);", Schema: f.schema})
					if err == nil && r.GetOutcome() != pb.PublicationOutcome_COMMITTED {
						err = context.Canceled
					}
					published <- err
				}()
				select {
				case err := <-published:
					t.Fatalf("publication passed live final-use custody: %v", err)
				case <-time.After(60 * time.Millisecond):
				}
			}
			releaseHeaders.Do(func() { close(headers) })
			if revoke {
				select {
				case err := <-published:
					if err != nil {
						t.Fatal(err)
					}
				case <-ctx.Done():
					t.Fatal("revocation could not drain live sends")
				}
			}
			releaseTail.Do(func() { close(tail) })
			for range 2 {
				if err := <-done; (err != nil) != revoke {
					t.Fatalf("unexpected execution outcome: revoke=%v err=%v", revoke, err)
				}
			}
			f.stop(t)
			f.start(t)
			for _, plan := range plans {
				if _, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
					t.Fatal("restart reopened consumed domain")
				}
				r, err := f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: plan.Family, Node: plan.Node})
				if err != nil || r.GetHeld() != 4 {
					t.Fatalf("original exposure changed: %v %v", r, err)
				}
			}
			if f.primary.Load() != 2 || f.backup.Load() != 0 {
				t.Fatal("parallel execution caused retry or fallback")
			}
		})
	}
}
