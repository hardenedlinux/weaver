// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"path/filepath"
	"testing"
	"testing/quick"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/protobuf/proto"
)

func TestProviderMutationCASOverlapsFinalSend(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	for _, schedule := range []struct{ mutation, cut string }{
		{"policy", "before"}, {"policy", "after"}, {"stale-policy", "before"},
		{"migration", "before"}, {"migration", "after"},
	} {
		t.Run(schedule.mutation+"/"+schedule.cut, func(t *testing.T) {
			providerMutationRace(t, observedServer(t), schedule.mutation, schedule.cut, pb.Encoding_PROTOBUF, true)
		})
	}
}

func TestProviderPolicyPrecommitFaultProperty(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	image := observedServer(t)
	check := func(selector uint8) bool {
		mutation := "policy"
		if selector&1 != 0 {
			mutation = "stale-policy"
		}
		encoding := pb.Encoding_PROTOBUF
		if selector&2 != 0 {
			encoding = pb.Encoding_ARROW_IPC
		}
		t.Logf("generated Policy fault selector=%d (%s/%s)", selector, mutation, encoding)
		providerMutationRace(t, image, mutation, "before", encoding, true)
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 4, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}

// Each ABBA block changes only the observer cut. Both arms use the same
// observed server executable, fresh stores and the same fault observer.
func BenchmarkProviderMutationCASPair(b *testing.B) {
	b.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	image := filepath.Join(b.TempDir(), "observed-server")
	digest, err := publishProviderImage(observedServer(b), image)
	if err != nil {
		b.Fatal(err)
	}
	b.Logf("paired observed image sha256=%s", digest)
	for _, mutation := range []string{"policy", "migration"} {
		for i, cut := range []string{"after", "before", "before", "after"} {
			b.Run(fmt.Sprintf("%s/%d-%s", mutation, i, cut), func(b *testing.B) {
				b.StopTimer()
				var elapsed time.Duration
				for range b.N {
					elapsed += providerMutationRace(b, image, mutation, cut, pb.Encoding_PROTOBUF, false)
				}
				b.ReportMetric(float64(elapsed.Nanoseconds())/float64(b.N), "mutation-ns/op")
				b.ReportMetric(0, "ns/op")
			})
		}
	}
}

type mutationResult struct {
	committed bool
	err       error
	recover   func(context.Context) error
}

func providerMutationRace(t testing.TB, image, mutation, cut string, encoding pb.Encoding, restart bool) time.Duration {
	t.Helper()
	controller := observeCommit(t)
	bodyRead := make(chan struct{}, 1)
	f := fixtureWithInvocation(t, func(w http.ResponseWriter, r *http.Request) {
		if _, err := io.Copy(io.Discard, r.Body); err != nil {
			t.Error(err)
			return
		}
		select {
		case bodyRead <- struct{}{}:
		default:
		}
		completeSSE(w, r)
	}, false, image, []string{"--exact", "provider_commit_tests::serve_observed_gateway", "--ignored", "--nocapture"},
		[]string{"WEAVER_TEST_COMMIT_SOCKET=" + controller.path, "WEAVER_TEST_COMMIT_CUT=" + cut})
	bundle := controlBundle(t, f)
	control := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	control.start(t)
	t.Cleanup(func() { control.stop(t) })
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	controller.await(t, ctx, "Boot", 0)
	if _, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: "control"}); err != nil {
		t.Fatal(err)
	}

	mutate := func(id string) mutationResult {
		if mutation == "migration" {
			command := &pb.DomainMigration{OperationId: id, BudgetFrom: "control", BudgetTo: "f", HistoryFrom: "control", HistoryTo: "f",
				BudgetFromEpoch: 1, BudgetToEpoch: 1, HistoryFromEpoch: 1, HistoryToEpoch: 1}
			receipt, err := f.admin.RPC.MigrateExecutionDomains(f.admin.Context(ctx), command)
			return mutationResult{receipt.GetCommitted(), err, func(ctx context.Context) error {
				replayed, err := f.admin.RPC.MigrateExecutionDomains(f.admin.Context(ctx), command)
				if err == nil && !proto.Equal(receipt, replayed) {
					err = errors.New("migration outcome changed")
				}
				return err
			}}
		}
		parent := bundle.View().Revision
		publication := bundle.Publication
		publication.OperationID, publication.ExpectedRevision = id, &parent
		publication.Fence++
		publication.Policy = "forbid(principal,action,resource);"
		rpc := f.admin.RPC
		if mutation == "stale-policy" && id == "racing-a" {
			// A stale parent may be rejected without review. Bypass only the test
			// decorator so that this exact final RPC reaches the held send scope.
			parent--
			rpc = rpc.(*fixtureReviewer).GatewayClient
		}
		receipt, err := rpc.PublishAuthority(f.admin.Context(ctx), gatewayclient.Publication(publication))
		if err == nil && receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED && receipt.GetOutcome() != pb.PublicationOutcome_REJECTED {
			err = errors.New("missing durable publication decision")
		}
		return mutationResult{receipt.GetOutcome() == pb.PublicationOutcome_COMMITTED, err, func(ctx context.Context) error {
			replayed, err := f.admin.InspectPublication(ctx, publication)
			if err == nil && !proto.Equal(receipt, replayed) {
				err = errors.New("publication outcome changed")
			}
			return err
		}}
	}
	results := make(chan mutationResult, 1)
	done := make(chan error, 1)
	go func() {
		_, err := control.client.Execute(ctx, bundle.Plans[0], encoding, 1, func(*pb.Event) error {
			t.Error("unconfirmed dispatch emitted a frame")
			return nil
		})
		done <- err
	}()
	phase, marker, decision := "BeforeCommit", 1, byte('r')
	if cut == "after" {
		phase, marker, decision = "AfterCommit", 2, 'l'
	}
	arrival := "Mutation"
	switch mutation {
	case "policy":
		arrival = "Stage"
	case "stale-policy":
		arrival = "Publish"
	}
	var event commitCut
	var start time.Time
	launch := func() {
		start = time.Now()
		go func() { results <- mutate("racing-a") }()
	}
	if cut == "before" {
		select {
		case <-bodyRead:
		case <-ctx.Done():
			t.Fatal("provider did not receive complete TLS request")
		}
		launch()
		// Body receipt triggers the mutation; scheduling can deliver either observation first.
		for range 2 {
			select {
			case observed := <-controller.events:
				switch {
				case observed.phase == phase && observed.marker == marker:
					event = observed
					defer event.socket.Close()
				case observed.phase == arrival && observed.marker == 0:
				default:
					t.Fatalf("unexpected race observation: %+v", observed)
				}
			case <-ctx.Done():
				t.Fatal("missing send or mutation observation", ctx.Err())
			}
		}
		if event.socket == nil {
			t.Fatal("missing actual provider commit cut")
		}
	} else {
		event = controller.await(t, ctx, phase, marker)
		defer event.socket.Close()
		launch()
		controller.await(t, ctx, arrival, 0)
	}
	if cut == "before" {
		select {
		case unexpected := <-controller.events:
			t.Fatalf("source advanced during live send scope: %s", unexpected.phase)
		case outcome := <-results:
			assertNoFaultWorkerUnwind(t, f)
			t.Fatalf("mutation completed inside live send scope after %s: committed=%v err=%v", time.Since(start), outcome.committed, outcome.err)
		case <-time.After(30 * time.Millisecond):
		}
		resumeCommit(t, event, decision)
	}
	var first mutationResult
	select {
	case first = <-results:
	case <-ctx.Done():
		t.Fatal("admitted source mutation did not resolve", ctx.Err())
	}
	// Reviewed publication must progress from staging to the actual final
	// CAS. In the before arm this event must follow release of the send scope.
	if mutation == "policy" {
		controller.await(t, ctx, "Publish", 0)
	}
	// The other operation uses the same parent or epochs for the positive race.
	// The negative stale-policy arm instead follows its rejection with a
	// reviewed publication from the current parent.
	second := mutate("racing-b")
	elapsed := time.Since(start)
	if cut == "after" {
		resumeCommit(t, event, decision)
	}
	if first.err != nil || second.err != nil || first.committed != (mutation != "stale-policy") || second.committed != (mutation == "stale-policy") {
		t.Fatalf("expected one durable first and one stale rejection: first=%v/%v second=%v/%v", first.committed, first.err, second.committed, second.err)
	}
	if err := <-done; err == nil {
		t.Fatal("unconfirmed native result succeeded")
	}
	if cut == "after" {
		select {
		case <-bodyRead:
		case <-ctx.Done():
			t.Fatal("provider did not receive complete TLS request")
		}
	}
	assertNoFaultWorkerUnwind(t, f)
	if restart {
		control.stop(t)
		f.stop(t)
		f.start(t)
		controller.await(t, ctx, "Boot", marker)
		control.start(t)
	}
	for _, outcome := range []mutationResult{first, second} {
		if err := outcome.recover(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := control.client.Execute(ctx, bundle.Plans[0], encoding, 1, func(*pb.Event) error {
		t.Error("replay emitted a frame")
		return nil
	}); err == nil {
		t.Fatal("replay reopened original")
	}
	receipt, err := f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: "control", Node: "infer"})
	if err != nil || receipt.GetState() != "unknown" || receipt.GetHeld() != 4 || receipt.GetEvents() != 0 {
		t.Fatalf("uncertain dispatch state changed: %v %v", receipt, err)
	}
	view, err :=
		f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: "control"})
	if err != nil || view.GetHeld() != 4 || view.GetHistoryCount() != 1 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatalf("original exposure or provider calls changed: %v %v primary=%d backup=%d", view, err, f.primary.Load(), f.backup.Load())
	}
	control.stop(t)
	f.stop(t)
	return elapsed
}
