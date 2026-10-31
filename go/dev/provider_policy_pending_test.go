//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
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

// Credential rollback cannot lower the local persistent source-key floor or
// remove original consumption. Independent whole-store anti-rollback remains separate.
func TestProviderSourceRollbackLostReplyRetainsUnknownConsumption(t *testing.T) {
	for _, phase := range []string{"stage", "commit"} {
		t.Run(phase, func(t *testing.T) {
			f := newFixture(t, partialRequestDisconnect, true)
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil {
				t.Fatal("partial request was treated as complete")
			}
			before := inspect(t, f)
			if before.State != "unknown" || before.Held != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
				t.Fatal("original unknown consumption missing", before)
			}
			oldCertificate := f.pki.source
			original := pendingChange(f, "rollback-unknown-consumption")
			relay := &publicationReplyLoss{source: f.admin, loseStage: phase == "stage"}
			if phase == "stage" {
				if _, err := relay.StageAuthority(ctx, gatewayclient.Publication(original)); status.Code(err) != codes.Unavailable {
					t.Fatal("durable stage reply was not lost", err)
				}
			} else {
				if err := f.admin.StagePublication(ctx, original); err != nil {
					t.Fatal(err)
				}
				if _, err := relay.PublishAuthority(ctx, gatewayclient.Publication(original)); status.Code(err) != codes.Unavailable {
					t.Fatal("durable commit reply was not lost", err)
				}
			}
			next := secondaryClient(t, f.pki)
			rotateAndRestartSource(t, f, next)
			_, err := f.admin.InspectPublication(ctx, original)
			if phase == "stage" && status.Code(err) != codes.NotFound || phase == "commit" && err != nil {
				t.Fatal("credential rotation changed the original outcome", err)
			}
			// Restore the retired startup identity, retaining the actual source DB.
			restartWithSourceCertificate(t, f, oldCertificate)
			if _, err := f.admin.ObserveOrPublish(ctx, original); status.Code(err) != codes.PermissionDenied {
				t.Fatal("retired startup credential regained publication", err)
			}
			restartWithSourceCertificate(t, f, next)
			outcome, err := f.admin.ObserveOrPublish(ctx, original)
			if err != nil || outcome.GetOutcome() != pb.PublicationOutcome_COMMITTED || outcome.GetRevision() != 1 {
				t.Fatal("exact original outcome could not reconcile", outcome, err)
			}
			f.plan.Revision, f.plan.Fence = 1, 2
			if _, _, err := execute(t, f, pb.Encoding_ARROW_IPC, 2); err == nil {
				t.Fatal("credential configuration rollback reopened the original claim")
			}
			after := inspect(t, f)
			if after.State != "unknown" || after.Held != before.Held || after.Reserved != before.Reserved || f.primary.Load() != 1 || f.backup.Load() != 0 {
				t.Fatal("lost reply or restored credential reset unknown exposure", after)
			}
		})
	}
}

// Startup transport pin only: deliberately does not change durable authority.
func restartWithSourceCertificate(t *testing.T, f *fixture, next tls.Certificate) {
	t.Helper()
	f.stop(t)
	f.pki.source = next
	digest := sha256.Sum256(next.Certificate[0])
	const key = "WEAVER_GRPC_SOURCE_PEER_SHA256"
	found := false
	for i, value := range f.env {
		name, _, _ := strings.Cut(value, "=")
		if name == key {
			f.env[i] = key + "=" + hex.EncodeToString(digest[:])
			found = true
		}
	}
	if !found {
		t.Fatal("source certificate admission setting missing")
	}
	f.start(t)
}
func rotateAndRestartSource(t *testing.T, f *fixture, next tls.Certificate) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	current, err := f.admin.SourceAuthority(ctx)
	if err != nil {
		t.Fatal(err)
	}
	token := sha256.Sum256([]byte(f.admin.Token))
	receipt, err := f.admin.RotateSource(ctx, v1.SourceRotation{OperationID: fmt.Sprintf("source-handoff-%d", current.Epoch), ExpectedEpoch: current.Epoch, NextCertificate: next.Certificate[0], NextCredentialSHA256: hex.EncodeToString(token[:])})
	if err != nil || receipt.GetOutcome() != pb.SourceRotationOutcome_SOURCE_ROTATED {
		t.Fatal("durable source handoff", receipt, err)
	}
	restartWithSourceCertificate(t, f, next)
}

func TestProviderSourceCertificateRotationRecoversLostReplyAndPending(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	oldCertificate := f.pki.source
	oldToken := f.admin.Token
	oldTLS := &tls.Config{RootCAs: f.pki.root, Certificates: []tls.Certificate{oldCertificate}, ServerName: "localhost", MinVersion: tls.VersionTLS13}
	next := secondaryClient(t, f.pki)
	oldLeaf, err := x509.ParseCertificate(oldCertificate.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	newLeaf, err := x509.ParseCertificate(next.Certificate[0])
	if err != nil || oldLeaf.Subject.String() != newLeaf.Subject.String() {
		t.Fatal("rotation must preserve the shared subject while changing its key", err)
	}
	a, b := pendingChange(f, "rotated-source-a"), pendingChange(f, "rotated-source-b")
	relay := &publicationReplyLoss{source: f.admin, loseStage: true}
	if _, err := relay.StageAuthority(ctx, gatewayclient.Publication(a)); status.Code(err) != codes.Unavailable {
		t.Fatal("durable staging reply was not lost", err)
	}
	if err := f.admin.StagePublication(ctx, b); err != nil {
		t.Fatal(err)
	}
	rotateAndRestartSource(t, f, next)
	oldWorker, err := gatewayclient.Dial(ctx, f.sourceAddress, oldToken, oldTLS)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { oldWorker.Connection.Close() })
	if err := oldWorker.StagePublication(ctx, a); status.Code(err) != codes.Unauthenticated {
		t.Fatal("old source key remained valid after rotation", err)
	}
	if _, err := oldWorker.RPC.PublishAuthority(oldWorker.Context(ctx), gatewayclient.Publication(a)); status.Code(err) != codes.Unauthenticated {
		t.Fatal("old key reached the final publication endpoint", err)
	}
	if _, err := f.admin.InspectPublication(ctx, a); status.Code(err) != codes.NotFound {
		t.Fatal("rotation fabricated a final outcome", err)
	}
	if _, err := f.admin.Publish(ctx, a); err != nil {
		t.Fatal("new source key could not continue the exact original command", err)
	}
	f.plan.Revision, f.plan.Fence = 1, 2
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil || f.primary.Load() != 0 {
		t.Fatal("credential rotation discarded sibling pending")
	}
	if _, err := f.admin.Publish(ctx, b); err != gatewayclient.ErrPublicationRejected {
		t.Fatal("old-parent sibling lost its original rejection", err)
	}
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err != nil {
		t.Fatal("resolved authority failed positive control", err)
	}
	f.stop(t)
	f.start(t)
	if _, _, err := execute(t, f, pb.Encoding_ARROW_IPC, 2); err == nil || f.primary.Load() != 1 || inspect(t, f).Held != 4 {
		t.Fatal("source rotation and restart reopened original consumption or hold")
	}
}

// Regression for the previously executed startup-pin rollback counterexample.
func TestProviderSourceCertificateConfigRollbackReacceptsOldKeyCounterexample(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	old := f.pki.source
	next := secondaryClient(t, f.pki)
	rotateAndRestartSource(t, f, next)
	if _, err := f.admin.Publish(ctx, pendingChange(f, "current-source-key")); err != nil {
		t.Fatal(err)
	}
	restartWithSourceCertificate(t, f, old)
	parent := uint64(1)
	proposal := pendingChange(f, "rolled-back-source-key")
	proposal.ExpectedRevision, proposal.Fence = &parent, 3
	if _, err := f.admin.Publish(ctx, proposal); status.Code(err) != codes.PermissionDenied {
		t.Fatal("retired startup identity regained authority", err)
	}
	restartWithSourceCertificate(t, f, next)
	if view, err := f.admin.SourceAuthority(ctx); err != nil || view.Epoch != 1 {
		t.Fatal("durable source floor changed", view, err)
	}
	if f.primary.Load() != 0 {
		t.Fatal("publication phase sent provider traffic")
	}
}

// Durable staging is the existing source-admission subset. It is not an
// implemented Delta artifact registry and must not be reported as one.
func TestProviderStagingLostReplyRetainsConcurrentPendingAcrossRestart(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	a, b := pendingChange(f, "unknown-register-a"), pendingChange(f, "unknown-register-b")
	relay := &publicationReplyLoss{source: f.admin, loseStage: true}
	if _, err := relay.StageAuthority(ctx, gatewayclient.Publication(a)); status.Code(err) != codes.Unavailable {
		t.Fatal("durable staging reply was not lost", err)
	}
	if err := f.admin.StagePublication(ctx, b); err != nil {
		t.Fatal(err)
	}
	f.stop(t)
	f.start(t)
	relay.replaceSource(f.admin)
	if _, err := f.admin.InspectPublication(ctx, a); status.Code(err) != codes.NotFound {
		t.Fatal("unknown registration became a final outcome", err)
	}
	if _, err := relay.StageAuthority(ctx, gatewayclient.Publication(a)); err != nil {
		t.Fatal("exact original staging could not reconcile", err)
	}
	if _, err := f.admin.Publish(ctx, a); err != nil {
		t.Fatal(err)
	}
	f.plan.Revision, f.plan.Fence = 1, 2
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil || f.primary.Load() != 0 {
		t.Fatal("recovered original intent cleared its concurrent sibling")
	}
	if _, err := f.admin.Publish(ctx, b); err != gatewayclient.ErrPublicationRejected {
		t.Fatal("old-parent sibling did not resolve independently", err)
	}
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err != nil {
		t.Fatal("resolved original authority failed positive control", err)
	}
	f.stop(t)
	f.start(t)
	if _, err := f.admin.ObserveOrPublish(ctx, a); err != nil {
		t.Fatal("historical original outcome was lost", err)
	}
	if _, _, err := execute(t, f, pb.Encoding_ARROW_IPC, 2); err == nil || f.primary.Load() != 1 || inspect(t, f).Held != 4 {
		t.Fatal("late historical outcome reopened original consumption or hold")
	}
}

func TestProviderConcurrentSameIDStagingHasOneDurableBinding(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	a := pendingChange(f, "concurrent-registration")
	b := a
	b.Policy += "\n"
	type outcome struct {
		command v1.Publication
		err     error
	}
	results := make(chan outcome, 2)
	for _, command := range []v1.Publication{a, b} {
		go func(command v1.Publication) { results <- outcome{command, f.admin.StagePublication(ctx, command)} }(command)
	}
	var winner, loser v1.Publication
	success := 0
	for range 2 {
		r := <-results
		if r.err == nil {
			winner = r.command
			success++
		} else {
			// The unchanged bounded source lane may reject before CAS. A
			// sequential retry below must then prove the exact durable conflict.
			if code := status.Code(r.err); code != codes.FailedPrecondition && code != codes.ResourceExhausted {
				t.Fatal("unexpected concurrent staging failure", r.err)
			}
			loser = r.command
		}
	}
	if success != 1 {
		t.Fatal("concurrent registration did not select exactly one binding", success)
	}
	if err := f.admin.StagePublication(ctx, loser); status.Code(err) != codes.FailedPrecondition {
		t.Fatal("losing retry was not rejected by the durable binding", err)
	}
	f.stop(t)
	f.start(t)
	if err := f.admin.StagePublication(ctx, winner); err != nil {
		t.Fatal("restart lost the winning exact binding", err)
	}
	if _, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), gatewayclient.Publication(loser)); status.Code(err) != codes.FailedPrecondition {
		t.Fatal("losing command bypassed final publication binding", err)
	}
	if _, err := f.admin.Publish(ctx, winner); err != nil || f.primary.Load() != 0 {
		t.Fatal("winning publication failed or triggered external send", err)
	}
}

// Expected coverage boundary: a source-role credential survives process restart.
// It does not yet authenticate a newly fenced registrar incarnation or artifact.
func TestProviderSourceRoleCredentialIsNotRegistrarIncarnationEvidence(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	oldToken := f.admin.Token
	oldIdentity := &tls.Config{RootCAs: f.pki.root, Certificates: []tls.Certificate{f.pki.source}, ServerName: "localhost", MinVersion: tls.VersionTLS13}
	f.stop(t)
	f.start(t)
	oldWorker, err := gatewayclient.Dial(ctx, f.sourceAddress, oldToken, oldIdentity)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { oldWorker.Connection.Close() })
	if _, err := oldWorker.Publish(ctx, pendingChange(f, "retained-source-credential")); err != nil {
		t.Fatal("source-role coverage boundary changed; audit incarnation enforcement", err)
	}
	if f.primary.Load() != 0 {
		t.Fatal("publication phase sent externally")
	}
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
