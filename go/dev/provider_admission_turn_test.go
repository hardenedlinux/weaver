// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"math/rand"
	"sync/atomic"
	"testing"
	"testing/quick"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestProviderAdmissionTurnGate(t *testing.T) {
	for _, mode := range []string{"early", "selected", "revoke"} {
		t.Run(mode, func(t *testing.T) { checkAdmissionTurn(t, mode) })
	}
}
func TestProviderAdmissionTurnProperty(t *testing.T) {
	property := func(early, revoke bool) bool {
		mode := "selected"
		if early {
			mode = "early"
		}
		if revoke {
			mode = "revoke"
		}
		checkAdmissionTurn(t, mode)
		return true
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 4, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}
func checkAdmissionTurn(t *testing.T, mode string) {
	t.Helper()
	controller := observeCommit(t)
	env := []string{"WEAVER_STORAGE_JOURNAL=mvcc", "WEAVER_TEST_COMMIT_SOCKET=" + controller.path,
		"WEAVER_TEST_COMMIT_CUT=admission-queued", "WEAVER_TEST_ADMISSION_FAMILY=right", "WEAVER_TEST_RECEIVER_PAUSE=1"}
	if mode == "early" {
		env = append(env, "WEAVER_TEST_EARLY_ADMISSION_BARRIER=1")
	}
	f := fixtureWithInvocation(t, burstProviderSSE(13), false, observedServer(t),
		[]string{"--exact", "provider_commit_tests::serve_observed_gateway", "--ignored", "--nocapture"}, env)
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	controller.await(t, ctx, "Boot", 0)
	plans := boundProviderPlans(t, f, 8)
	first := make(chan struct{}, 1)
	leftDone := make(chan error, 1)
	rightDone := make(chan error, 1)
	var rows atomic.Int64
	go func() {
		_, err := f.client.Execute(ctx, plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error {
			if rows.Add(1) == 1 {
				first <- struct{}{}
			}
			return nil
		})
		leftDone <- err
	}()
	receiver := controller.await(t, ctx, "BeforeReceiverHandoff", 0)
	go func() {
		_, err := f.client.Execute(ctx, plans[1], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
		rightDone <- err
	}()
	waiting := controller.await(t, ctx, "BeforeAdmissionSchedule", 1)
	view, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: "left"})
	if err != nil || view.GetHeld() != 4 || view.GetHistoryCount() != 1 {
		t.Fatal("unaccepted request changed shared evidence", view, err)
	}
	if mode == "revoke" {
		parent := uint64(1)
		r, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "revoke-queued-admission", ExpectedRevision: &parent, Fence: 3, Policy: "forbid(principal,action,resource);", Schema: f.schema})
		if err != nil || r.GetOutcome() != pb.PublicationOutcome_COMMITTED {
			t.Fatal("hard source change", r, err)
		}
	}
	resumeCommit(t, receiver, 'c')
	if mode == "selected" {
		select {
		case <-first:
		case <-time.After(300 * time.Millisecond):
			t.Fatal("unaccepted request blocked a qualified old frame")
		}
		if f.primary.Load() != 1 {
			t.Fatal("new request called a provider before admission")
		}
	} else {
		select {
		case <-first:
			t.Fatal("closed or revoked frame escaped")
		case <-time.After(40 * time.Millisecond):
		}
	}
	resumeCommit(t, waiting, 'c')
	left, right := <-leftDone, <-rightDone
	if mode == "revoke" {
		if left == nil || right == nil || rows.Load() != 0 || f.primary.Load() != 1 {
			t.Fatal("revocation crossed final use", left, right, rows.Load(), f.primary.Load())
		}
	} else if left != nil || right != nil || rows.Load() != 13 || f.primary.Load() != 2 {
		t.Fatal("authorized streams failed", left, right, rows.Load(), f.primary.Load())
	}
	f.stop(t)
	f.start(t)
	marker := 1
	held, history, calls := uint64(4), uint64(1), int64(1)
	if mode != "revoke" {
		marker = 2
		held = 8
		history = 2
		calls = 2
	}
	controller.await(t, ctx, "Boot", marker)
	view, err = f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: "left"})
	if err != nil || view.GetHeld() != held || view.GetHistoryCount() != history {
		t.Fatal("restart changed original exposure", view, err)
	}
	for i, plan := range plans {
		retry := make(chan error, 1)
		go func() {
			_, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
			retry <- err
		}()
		if i == 1 {
			pause := controller.await(t, ctx, "BeforeAdmissionSchedule", marker)
			resumeCommit(t, pause, 'c')
		}
		if err := <-retry; err == nil {
			t.Fatal("SDK retry reopened an original claim")
		}
	}
	if f.primary.Load() != calls || f.backup.Load() != 0 {
		t.Fatal("restart duplicated/substituted execution")
	}
	f.stop(t)
}

func TestProviderAdmissionCommitRecovery(t *testing.T) {
	for _, journal := range []string{"wal", "mvcc"} {
		for _, mode := range []string{"control", "rollback-before", "crash-before", "lost-after", "crash-after"} {
			t.Run(journal+"/"+mode, func(t *testing.T) { checkAdmissionRecovery(t, journal, mode) })
		}
	}
}
func checkAdmissionRecovery(t *testing.T, journal, mode string) {
	t.Helper()
	before := mode == "rollback-before" || mode == "crash-before"
	cut, phase, marker := "admission-after", "AfterAdmissionCommit", 1
	if before {
		cut, phase, marker = "admission-before", "BeforeAdmissionCommit", 0
	}
	controller := observeCommit(t)
	f := fixtureWithInvocation(t, completeSSE, false, observedServer(t),
		[]string{"--exact", "provider_commit_tests::serve_observed_gateway", "--ignored", "--nocapture"},
		[]string{"WEAVER_STORAGE_JOURNAL=" + journal, "WEAVER_TEST_COMMIT_SOCKET=" + controller.path, "WEAVER_TEST_COMMIT_CUT=" + cut})
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	controller.await(t, ctx, "Boot", 0)
	done := make(chan error, 1)
	go func() {
		_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
		done <- err
	}()
	event := controller.await(t, ctx, phase, marker)
	switch mode {
	case "control":
		resumeCommit(t, event, 'c')
	case "rollback-before":
		resumeCommit(t, event, 'r')
	case "lost-after":
		resumeCommit(t, event, 'l')
	default:
		if err := f.child.Process.Kill(); err != nil {
			t.Fatal(err)
		}
		select {
		case <-f.exited:
		case <-ctx.Done():
			t.Fatal("injected crash did not finish")
		}
		f.child = nil
		f.client.Connection.Close()
		f.admin.Connection.Close()
		event.socket.Close()
	}
	err := <-done
	if (err == nil) != (mode == "control") {
		t.Fatal("unexpected admission result", mode, err)
	}
	if f.child != nil {
		assertNoFaultWorkerUnwind(t, f)
		f.stop(t)
	}
	f.start(t)
	controller.await(t, ctx, "Boot", marker)
	key := &pb.OperationKey{Family: f.plan.Family, Node: f.plan.Node}
	receipt, err := f.client.RPC.Inspect(f.client.Context(ctx), key)
	if before {
		if status.Code(err) != codes.FailedPrecondition {
			t.Fatal("missing original operation did not follow the Inspect contract", receipt, err)
		}
		view, viewErr := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: f.plan.Family})
		if viewErr != nil || view.GetHeld() != 0 || view.GetHistoryCount() != 0 || f.primary.Load() != 0 {
			t.Fatal("uncommitted admission left a hold, history or invocation", view, viewErr)
		}
	} else if err != nil || receipt.GetHeld() != 4 || receipt.GetState() != map[bool]string{true: "complete", false: "queued"}[mode == "control"] {
		t.Fatal("admission outcome or original hold lost", receipt, err)
	}
	if mode != "control" {
		// No invoke consumption exists yet: resume exactly the original queued
		// operation, retaining its digest and reservation, rather than a new key.
		if before {
			retry := make(chan error, 1)
			go func() {
				_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
				retry <- err
			}()
			pause := controller.await(t, ctx, phase, 0)
			resumeCommit(t, pause, 'c')
			if err := <-retry; err != nil {
				t.Fatal("known absent original did not resume", err)
			}
		} else {
			// Idempotent enqueue still commits its existing plan once. Confirm
			// that exact after-commit cut before permitting the first invoke.
			retry := make(chan error, 1)
			go func() {
				_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
				retry <- err
			}()
			pause := controller.await(t, ctx, phase, 1)
			resumeCommit(t, pause, 'c')
			if err := <-retry; err != nil {
				t.Fatal("queued original did not resume", err)
			}
		}
	}
	if f.primary.Load() != 1 || f.backup.Load() != 0 || inspect(t, f).Held != 4 {
		t.Fatal("recovery duplicated send or released original hold")
	}
	if _, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("completed original replayed")
	}
	f.stop(t)
}
