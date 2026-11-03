// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"strings"
	"sync"
	"testing"
	"testing/quick"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestProviderSharedDomainsProperty(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	property := func(raw uint8, reverse bool) bool {
		f := newFixture(t, completeSSE, false)
		defer f.stop(t)
		cap := uint64(4 + raw%5)
		plans := boundProviderPlans(t, f, cap)
		if reverse {
			plans[0], plans[1] = plans[1], plans[0]
		}
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		expected := uint64(0)
		for _, plan := range plans {
			_, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
			allowed := expected+plan.Ceiling <= cap
			if (err == nil) != allowed {
				return false
			}
			if allowed {
				expected += plan.Ceiling
			}
			view, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: plan.Family})
			if err != nil || view.GetHeld() != expected || view.GetHistoryCount() != expected/4 {
				return false
			}
		}
		return uint64(f.primary.Load()) == expected/4
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 8, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}

func TestProviderSharedDomainsCedarReadsCurrentAuthority(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	f := newFixture(t, completeSSE, false)
	plans := boundProviderPlans(t, f, 8)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	revision := uint64(1)
	policy := f.policy + ` forbid(principal,action == Weaver::Action::"invokeProvider",resource) when {
      !(context has budget_domain && context.budget_domain == "shared" &&
        context has shared_held && context.shared_held == 4 &&
        context has history_count && context.history_count == 1)
    };`
	// Retain the existing task-family scope in the allow policy.
	policy = strings.Replace(policy, `context.family == "f"`, `["left", "right"].contains(context.family)`, 1)
	receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "current-domain-policy", ExpectedRevision: &revision, Fence: 3, Policy: policy, Schema: f.schema})
	if err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatalf("typed domain policy: %v %v", receipt, err)
	}
	for index, plan := range plans {
		plan.Revision = 2
		plan.Fence = 3
		_, err = f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
		if (err == nil) != (index == 0) {
			t.Fatalf("Cedar used stale shared facts at %d: %v", index, err)
		}
	}
	if f.primary.Load() != 1 {
		t.Fatal("Cedar did not constrain actual provider sends")
	}
	view, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: "right"})
	if err != nil || view.GetHeld() != 8 || view.GetHistoryCount() != 2 {
		t.Fatalf("denied consume erased original reservation: %v %v", view, err)
	}
}

func TestProviderSharedDomainsConcurrentFamiliesAndRestart(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	f := newFixture(t, completeSSE, false)
	plans := boundProviderPlans(t, f, 4)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	results := make(chan error, 2)
	for _, plan := range plans {
		go func() {
			_, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
			results <- err
		}()
	}
	success := 0
	for range 2 {
		if err := <-results; err == nil {
			success++
		}
	}
	if success != 1 || f.primary.Load() != 1 {
		t.Fatalf("shared budget split: successes=%d calls=%d", success, f.primary.Load())
	}
	inspect := func(family string) *pb.DomainView {
		t.Helper()
		v, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: family})
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	before := inspect("left")
	if before.Held != 4 || before.HistoryCount != 1 {
		t.Fatalf("original exposure: %v", before)
	}
	if _, err := f.client.RPC.RegisterFamilyAlias(f.client.Context(ctx), &pb.FamilyAliasRequest{Family: "sdk-retry", Origin: "left"}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("operation credential registered origin alias: %v", err)
	}
	alias, err := f.admin.RPC.RegisterFamilyAlias(f.admin.Context(ctx), &pb.FamilyAliasRequest{Family: "reconnect", Origin: "left"})
	if err != nil || alias.GetCanonicalFamily() != "left" {
		t.Fatalf("alias: %v %v", alias, err)
	}
	retry := plans[0]
	retry.Family = "reconnect"
	if _, err = f.client.Execute(ctx, retry, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("alias created a new execution")
	}
	f.stop(t)
	f.start(t)
	after := inspect("right")
	if after.Held != 4 || after.HistoryCount != 1 || after.GetStamp().GetBudgetRoot() != "shared" {
		t.Fatalf("restart reset shared exposure: %v", after)
	}
	for _, plan := range plans {
		if _, err = f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
			t.Fatal("SDK retry escaped original constraint")
		}
	}
	if f.primary.Load() != 1 {
		t.Fatal("duplicate provider send")
	}
}

func TestProviderDomainMigrationFencesStreamingReleaseAndRecoversLostReply(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	proceed := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(proceed) }) })
	f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		emitChunk(w, "prefix", false)
		<-proceed
		emitChunk(w, "tail", false)
		emitChunk(w, "", true)
		fmt.Fprint(w, "data: [DONE]\n\n")
	}, false)
	plans := independentProviderPlans(t, f)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	first := make(chan struct{}, 1)
	done := make(chan error, 1)
	var text string
	go func() {
		_, err := f.client.Execute(ctx, plans[0], pb.Encoding_PROTOBUF, 1, func(e *pb.Event) error {
			text += e.Text
			select {
			case first <- struct{}{}:
			default:
			}
			return nil
		})
		done <- err
	}()
	select {
	case <-first:
	case <-ctx.Done():
		t.Fatal("authorized prefix missing")
	}
	command := &pb.DomainMigration{OperationId: "union-original-domains", BudgetFrom: "left", BudgetTo: "right", HistoryFrom: "left", HistoryTo: "right", BudgetFromEpoch: 1, BudgetToEpoch: 1, HistoryFromEpoch: 1, HistoryToEpoch: 1}
	receipt, err := f.admin.RPC.MigrateExecutionDomains(f.admin.Context(ctx), command)
	if err != nil || !receipt.GetCommitted() {
		t.Fatalf("union: %v %v", receipt, err)
	}
	// Treat the response as lost. Recovery must return this exact receipt even
	// though the root heads have advanced; the original parent is not rebased.
	once.Do(func() { close(proceed) })
	if err = <-done; err == nil {
		t.Fatal("pre-migration streaming owner released tail")
	}
	if text != "prefix" {
		t.Fatalf("stale release: %q", text)
	}
	f.stop(t)
	f.start(t)
	recovered, err := f.admin.RPC.MigrateExecutionDomains(f.admin.Context(ctx), command)
	if err != nil || !proto.Equal(receipt, recovered) {
		t.Fatalf("lost-reply recovery changed outcome: %v %v", recovered, err)
	}
	view, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: "left"})
	if err != nil || view.GetHeld() != 4 || view.GetHistoryCount() != 1 || view.GetStamp().GetBudgetEpoch() != 2 {
		t.Fatalf("migration lost original exposure: %v %v", view, err)
	}
	if _, err = f.client.Execute(ctx, plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("migration replayed consumed invocation")
	}
	if f.primary.Load() != 1 {
		t.Fatal("migration duplicated send")
	}
}
