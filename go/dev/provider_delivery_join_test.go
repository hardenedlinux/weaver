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
)

func TestProviderDeliveryCommitAndReceiverRecovery(t *testing.T) {
	for _, journal := range []string{"wal", "mvcc"} {
		t.Run(journal, func(t *testing.T) {
			for _, mode := range []string{"control", "rollback", "lost-ack", "crash-before", "crash-after", "revoke-receiver", "late-same-policy", "crash-receiver", "migrate-receiver"} {
				t.Run(mode, func(t *testing.T) { checkProviderDeliveryJoin(t, journal, mode) })
			}
		})
	}
}

func TestProviderDeliveryReceiverProperty(t *testing.T) {
	property := func(mvcc, revoke bool) bool {
		journal, mode := "wal", "control"
		if mvcc {
			journal = "mvcc"
		}
		if revoke {
			mode = "revoke-receiver"
		}
		checkProviderDeliveryJoin(t, journal, mode)
		return true
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 4, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}

func checkProviderDeliveryJoin(t *testing.T, journal, mode string) {
	t.Helper()
	controller := observeCommit(t)
	before := mode == "rollback" || mode == "crash-before"
	cut, phase := "delivery-after", "AfterDeliveryCommit"
	if before {
		cut, phase = "delivery-before", "BeforeDeliveryCommit"
	}
	environment := []string{"WEAVER_STORAGE_JOURNAL=" + journal, "WEAVER_TEST_COMMIT_SOCKET=" + controller.path,
		"WEAVER_TEST_COMMIT_CUT=" + cut, "WEAVER_TEST_DELIVERY_OBSERVE=1"}
	if mode == "revoke-receiver" || mode == "late-same-policy" || mode == "crash-receiver" || mode == "migrate-receiver" {
		environment = append(environment, "WEAVER_TEST_RECEIVER_PAUSE=1")
	}
	f := fixtureWithInvocation(t, completeSSE, false, observedServer(t),
		[]string{"--exact", "provider_commit_tests::serve_observed_gateway", "--ignored", "--nocapture"}, environment)
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	controller.await(t, ctx, "Boot", 0)
	if mode == "migrate-receiver" {
		f.plan = independentProviderPlans(t, f)[0]
	}
	var frames atomic.Int64
	done := make(chan error, 1)
	go func() {
		_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { frames.Add(1); return nil })
		done <- err
	}()
	marker := 1
	if before {
		marker = 0
	}
	event := awaitDeliveryCuts(t, ctx, controller, phase, marker)
	if frames.Load() != 0 {
		t.Fatal("an unacknowledged queued frame reached Go", frames.Load())
	}
	switch mode {
	case "rollback":
		resumeCommit(t, event, 'r')
	case "lost-ack":
		resumeCommit(t, event, 'l')
	case "crash-before", "crash-after":
		if err := f.child.Process.Kill(); err != nil {
			t.Fatal(err)
		}
		select {
		case <-f.exited:
		case <-ctx.Done():
			t.Fatal("crashed owner did not exit")
		}
		f.child = nil
		f.client.Connection.Close()
		f.admin.Connection.Close()
		event.socket.Close()
	default:
		resumeCommit(t, event, 'c')
	}
	if mode == "revoke-receiver" || mode == "late-same-policy" || mode == "crash-receiver" || mode == "migrate-receiver" {
		owner := controller.await(t, ctx, "BeforeReceiverHandoff", 0)
		if mode == "migrate-receiver" {
			receipt, err := f.admin.RPC.MigrateExecutionDomains(f.admin.Context(ctx), &pb.DomainMigration{
				OperationId: "receiver-union", BudgetFrom: "left", BudgetTo: "right", HistoryFrom: "left", HistoryTo: "right",
				BudgetFromEpoch: 1, BudgetToEpoch: 1, HistoryFromEpoch: 1, HistoryToEpoch: 1})
			if err != nil || !receipt.GetCommitted() {
				t.Fatal("migration at acknowledged receiver", receipt, err)
			}
		} else if mode == "crash-receiver" {
			if err := f.child.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			select {
			case <-f.exited:
			case <-ctx.Done():
				t.Fatal("old receiver owner did not exit")
			}
			f.child = nil
			f.client.Connection.Close()
			f.admin.Connection.Close()
			owner.socket.Close()
		} else {
			revision := uint64(0)
			policy := "forbid(principal,action,resource);"
			if mode == "late-same-policy" {
				policy = f.policy
			}
			receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{
				OperationId: "after-ack-before-tonic", ExpectedRevision: &revision, Fence: 2, Policy: policy, Schema: f.schema})
			if err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
				t.Fatal("source cut did not commit while receiver held an old acknowledged proof", receipt, err)
			}
		}
		if mode != "crash-receiver" {
			resumeCommit(t, owner, 'c')
		}
	}
	select {
	case err := <-done:
		if mode == "control" {
			if err != nil || frames.Load() != 5 {
				t.Fatal("control stream failed", err, frames.Load())
			}
		} else if err == nil || frames.Load() != 0 {
			t.Fatal("old/unconfirmed delivery escaped final receiver", err, frames.Load())
		}
	case <-ctx.Done():
		t.Fatal("delivery did not finish within unchanged deadline")
	}
	if f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatal("delivery recovery retried upstream", f.primary.Load(), f.backup.Load())
	}
	if f.child != nil {
		f.stop(t)
	}
	f.start(t)
	recoveredRanges := 1
	if before {
		recoveredRanges = 0
	}
	if mode == "control" {
		recoveredRanges = 5
	}
	if mode == "revoke-receiver" || mode == "late-same-policy" || mode == "crash-receiver" || mode == "migrate-receiver" {
		// The paused sole receiver owns one staged frame and the real queue
		// holds two more. Native releases may commit concurrently, but none
		// may cross the paused receiver or become permission after restart.
		select {
		case event := <-controller.events:
			if event.phase != "Boot" || event.marker < 1 || event.marker > 3 {
				t.Fatal("recovery escaped the bounded inert pipeline", event.phase, event.marker)
			}
			recoveredRanges = event.marker
			t.Logf("exact recovered inert prefix=%d", recoveredRanges)
		case <-ctx.Done():
			t.Fatal("missing authoritative recovery prefix")
		}
	} else {
		controller.await(t, ctx, "Boot", recoveredRanges)
	}

	if _, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { t.Error("restarted original emitted a frame"); return nil }); err == nil {
		t.Fatal("restart reopened original consumption")
	}
	original, err := f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: f.plan.Family, Node: f.plan.Node})
	if err != nil || original.GetHeld() != 4 || (original.GetEvents() < uint64(max(1, recoveredRanges)) || original.GetEvents() > 5) || f.primary.Load() != 1 {
		t.Fatal("restart erased unknown reservation or repeated provider", original, err, f.primary.Load())
	}
	f.stop(t)
}

// Native commit and asynchronous receiver observation are independent.
func awaitDeliveryCuts(t testing.TB, ctx context.Context, controller *commitController, phase string, marker int) commitCut {
	t.Helper()
	var commit commitCut
	blocked := false
	for range 2 {
		select {
		case event := <-controller.events:
			switch event.phase {
			case phase:
				if commit.socket != nil || event.marker != marker {
					t.Fatal("wrong or duplicate durable release cut", event.phase, event.marker)
				}
				commit = event
			case "InertFrameBlocked":
				if blocked || event.marker != 0 {
					t.Fatal("wrong or duplicate inert receiver cut", event.phase, event.marker)
				}
				blocked = true
				event.socket.Close()
			default:
				t.Fatal("unexpected delivery observation", event.phase)
			}
		case <-ctx.Done():
			t.Fatal("actual commit/receiver cuts not observed within original window")
		}
	}
	if commit.socket == nil || !blocked {
		t.Fatal("incomplete real delivery evidence")
	}
	return commit
}

// Exercise the real TLS/Tonic producer and consumer with variable finite
// streams. Progress writes alone must never ask for full reauthorization.
func TestProviderSemanticProgressProperty(t *testing.T) {
	property := func(length uint8, mvcc, arrow bool) bool {
		journal := "wal"
		if mvcc {
			journal = "mvcc"
		}
		rows := 5 + int(length%9)
		f := fixtureWithInvocation(t, burstProviderSSE(rows), false, observedServer(t),
			[]string{"--exact", "grpc_config::serve_wif_gateway", "--ignored", "--nocapture"},
			[]string{"WEAVER_STORAGE_JOURNAL=" + journal, "WEAVER_TEST_PROVIDER_SCOPE_TRACE=1"})
		encoding := pb.Encoding_PROTOBUF
		if arrow {
			encoding = pb.Encoding_ARROW_IPC
		}
		ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
		defer cancel()
		frames := 0
		_, err := f.client.Execute(ctx, f.plan, encoding, 1, func(*pb.Event) error { frames++; return nil })
		if err != nil || frames != rows || f.primary.Load() != 1 || f.backup.Load() != 0 {
			t.Fatal("progress duplicated or lost a frame/request", err, frames, rows, f.primary.Load(), f.backup.Load())
		}
		// EOF joins the worker before its final trace is collected.
		f.stop(t)
		samples := readDeliverySamples(t, f)[f.plan.Family]
		if len(samples) != rows {
			t.Fatal("incomplete delivery trace", len(samples), rows)
		}
		for _, sample := range samples {
			if sample.refresh != 0 {
				t.Fatal("progress write invalidated an unchanged authorization image", sample.first, sample.refresh)
			}
		}
		return true
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 8, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}
