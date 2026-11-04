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
	"net/http"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/protobuf/proto"
)

func TestProviderMutationCASOverlapsFinalSend(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	for _, schedule := range []struct{ mutation, cut string }{
		{"policy", "after"}, {"migration", "before"}, {"migration", "after"},
	} {
		t.Run(schedule.mutation+"/"+schedule.cut, func(t *testing.T) {
			providerMutationRace(t, observedServer(t), schedule.mutation, schedule.cut, true)
		})
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
	for i, cut := range []string{"after", "before", "before", "after"} {
		b.Run(fmt.Sprintf("%d-%s", i, cut), func(b *testing.B) {
			b.StopTimer()
			var elapsed time.Duration
			for range b.N {
				elapsed += providerMutationRace(b, image, "migration", cut, false)
			}
			b.ReportMetric(float64(elapsed.Nanoseconds())/float64(b.N), "mutation-ns/op")
			b.ReportMetric(0, "ns/op")
		})
	}
}

type mutationResult struct {
	committed bool
	err       error
	recover   func(context.Context) error
}

func providerMutationRace(t testing.TB, image, mutation, cut string, restart bool) time.Duration {
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
		receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), gatewayclient.Publication(publication))
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
		_, err := control.client.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error {
			t.Error("unconfirmed dispatch emitted a frame")
			return nil
		})
		done <- err
	}()
	phase, marker, decision := "BeforeCommit", 1, byte('r')
	if cut == "after" {
		phase, marker, decision = "AfterCommit", 2, 'l'
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
				case observed.phase == "Mutation" && observed.marker == 0:
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
		controller.await(t, ctx, "Mutation", 0)
	}
	if cut == "before" {
		select {
		case outcome := <-results:
			assertNoFaultWorkerUnwind(t, f)
			t.Fatalf("mutation completed inside live send scope after %s: committed=%v err=%v", time.Since(start), outcome.committed, outcome.err)
		case <-time.After(30 * time.Millisecond):
		}
		resumeCommit(t, event, decision)
	}
	var winner mutationResult
	select {
	case winner = <-results:
	case <-ctx.Done():
		t.Fatal("admitted source mutation did not resolve", ctx.Err())
	}
	// The other operation retains its original parent or epochs.
	loser := mutate("racing-b")
	elapsed := time.Since(start)
	if cut == "after" {
		resumeCommit(t, event, decision)
	}
	if winner.err != nil || !winner.committed || loser.err != nil || loser.committed {
		t.Fatalf("expected one durable winner and one stale rejection: winner=%v/%v loser=%v/%v", winner.committed, winner.err, loser.committed, loser.err)
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
	for _, outcome := range []mutationResult{winner, loser} {
		if err := outcome.recover(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := control.client.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error {
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
