//go:build integration && !windows

package dev

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func pendingChange(f *fixture, id string) v1.Publication {
	parent := uint64(0)
	return v1.Publication{OperationID: id, ExpectedRevision: &parent, Fence: 2, Policy: f.policy, Schema: f.schema}
}

// This exercises the deployed command commitment, not Delta-artifact admission:
// the current wire protocol has no reviewed-artifact field.
func TestProviderPendingCommandSubstitutionAndHistoricalRecovery(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	original := pendingChange(f, "bound-review-command")
	if err := f.admin.StagePublication(ctx, original); err != nil {
		t.Fatal(err)
	}
	f.stop(t)
	f.start(t)
	parent := uint64(1)
	changedParent, changedFence, changedPolicy, changedSchema := original, original, original, original
	changedParent.ExpectedRevision = &parent
	changedFence.Fence++
	changedPolicy.Policy += "\n"
	changedSchema.Schema += "\n"
	for _, candidate := range []v1.Publication{changedParent, changedFence, changedPolicy, changedSchema} {
		if err := f.admin.StagePublication(ctx, candidate); status.Code(err) != codes.FailedPrecondition {
			t.Fatalf("replacement staging was not rejected: %v", err)
		}
		// Bypass the Go staging wrapper to exercise Rust's final endpoint too.
		if _, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), gatewayclient.Publication(candidate)); status.Code(err) != codes.FailedPrecondition {
			t.Fatalf("replacement final command was not rejected: %v", err)
		}
	}
	if _, err := f.admin.InspectPublication(ctx, original); status.Code(err) != codes.NotFound {
		t.Fatalf("failed replacement resolved the original pending intent: %v", err)
	}
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil || f.primary.Load() != 0 {
		t.Fatal("replacement attempts cleared pending or sent externally")
	}
	committed, err := f.admin.Publish(ctx, original)
	if err != nil || committed.GetRevision() != 1 {
		t.Fatal("original exact command could not complete", committed, err)
	}
	f.plan.Revision, f.plan.Fence = 1, 2
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err != nil {
		t.Fatal("exact original publication failed positive control", err)
	}
	if f.primary.Load() != 1 || inspect(t, f).Held != 4 {
		t.Fatal("positive control lost the original consumption or reservation")
	}
	oldParent := pendingChange(f, "old-parent-review-command")
	if receipt, err := f.admin.Publish(ctx, oldParent); err != gatewayclient.ErrPublicationRejected || receipt.GetOutcome() != pb.PublicationOutcome_REJECTED {
		t.Fatal("old parent did not produce an immutable rejection", receipt, err)
	}
	f.stop(t)
	f.start(t)
	for _, command := range []v1.Publication{original, oldParent} {
		if _, err := f.admin.InspectPublication(ctx, command); err != nil {
			t.Fatal("restart lost the exact original outcome", err)
		}
	}
	if _, _, err := execute(t, f, pb.Encoding_ARROW_IPC, 2); err == nil || f.primary.Load() != 1 || inspect(t, f).Held != 4 {
		t.Fatal("historical observations reopened consumption or released unknown budget")
	}
}

func TestProviderPendingPoliciesSurviveRestartAndResolveIndividually(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	a, b := pendingChange(f, "pending-a"), pendingChange(f, "pending-b")
	if err := f.client.StagePublication(ctx, a); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("operation identity could stage authority: %v", err)
	}
	for _, p := range []v1.Publication{a, b} {
		if err := f.admin.StagePublication(ctx, p); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil {
		t.Fatal("pending allowed invocation")
	}
	if f.primary.Load() != 0 {
		t.Fatal("staging or failed admission sent")
	}
	f.stop(t)
	f.start(t)
	if _, err := f.admin.InspectPublication(ctx, a); status.Code(err) != codes.NotFound {
		t.Fatal("pending became a decision", err)
	}
	if err := f.admin.StagePublication(ctx, a); err != nil {
		t.Fatal("lost staging response could not reconcile", err)
	}
	if _, err := f.admin.Publish(ctx, a); err != nil {
		t.Fatal(err)
	}
	f.plan.Revision, f.plan.Fence = 1, 2
	if _, _, err := execute(t, f, pb.Encoding_ARROW_IPC, 2); err == nil {
		t.Fatal("one decision cleared another pending intent")
	}
	if f.primary.Load() != 0 {
		t.Fatal("unresolved sibling allowed send")
	}
	if r, err := f.admin.Publish(ctx, b); err != gatewayclient.ErrPublicationRejected || r.GetOutcome() != pb.PublicationOutcome_REJECTED {
		t.Fatal("old parent was not an immutable rejection", r, err)
	}
	if _, _, err := execute(t, f, pb.Encoding_ARROW_IPC, 2); err != nil {
		t.Fatal("resolved current authority failed positive control", err)
	}
	if f.primary.Load() != 1 || inspect(t, f).Held != 4 {
		t.Fatal("wrong invocation or reservation count")
	}
	if err := f.admin.StagePublication(ctx, a); err != nil {
		t.Fatal(err)
	}
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil || f.primary.Load() != 1 || inspect(t, f).Held != 4 {
		t.Fatal("historical stage or SDK retry reopened original operation")
	}
}

func TestProviderPendingPolicyStopsTailWithoutRefundAfterRestart(t *testing.T) {
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
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	first := make(chan struct{}, 1)
	result := make(chan error, 1)
	var events []*pb.Event
	go func() {
		_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(event *pb.Event) error {
			events = append(events, event)
			select {
			case first <- struct{}{}:
			default:
			}
			return nil
		})
		result <- err
	}()
	select {
	case <-first:
	case <-ctx.Done():
		t.Fatal("authorized prefix missing")
	}
	p := pendingChange(f, "pending-tail")
	if err := f.admin.StagePublication(ctx, p); err != nil {
		t.Fatal(err)
	}
	once.Do(func() { close(proceed) })
	if err := <-result; err == nil {
		t.Fatal("pending Policy allowed a tail")
	}
	if len(events) != 1 || events[0].Text != "prefix" || inspect(t, f).Held != 4 {
		t.Fatal("tail escaped or hold released")
	}
	f.stop(t)
	f.start(t)
	if _, err := f.admin.Publish(ctx, p); err != nil {
		t.Fatal(err)
	}
	f.plan.Revision, f.plan.Fence = 1, 2
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil || f.primary.Load() != 1 || inspect(t, f).Held != 4 {
		t.Fatal("final decision and restart reopened consumed provider request")
	}
}
