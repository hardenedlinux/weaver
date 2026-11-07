// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"math/rand"
	"strings"
	"testing"
	"testing/quick"
	"time"
)

func TestProviderLifecycleCommitRecovery(t *testing.T) {
	for _, journal := range []string{"wal", "mvcc"} {
		for _, mode := range []string{"control", "rollback-before", "crash-before", "lost-after", "crash-after"} {
			t.Run(journal+"/"+mode, func(t *testing.T) { checkLifecycleRecovery(t, journal, mode) })
		}
	}
}
func TestProviderLifecycleRecoveryProperty(t *testing.T) {
	property := func(mvcc, before, crash bool) bool {
		journal := "wal"
		if mvcc {
			journal = "mvcc"
		}
		mode := "lost-after"
		if before {
			mode = "rollback-before"
		}
		if crash {
			mode = "crash-after"
			if before {
				mode = "crash-before"
			}
		}
		checkLifecycleRecovery(t, journal, mode)
		return true
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 4, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}
func checkLifecycleRecovery(t *testing.T, journal, mode string) {
	t.Helper()
	controller := observeCommit(t)
	before := strings.HasSuffix(mode, "before")
	cut, phase, marker := "lifecycle-after", "AfterLifecycleCommit", 1
	if before {
		cut, phase, marker = "lifecycle-before", "BeforeLifecycleCommit", 0
	}
	f := fixtureWithInvocation(t, completeSSE, false, observedServer(t), []string{"--exact", "provider_commit_tests::serve_observed_gateway", "--ignored", "--nocapture"}, []string{"WEAVER_STORAGE_JOURNAL=" + journal, "WEAVER_TEST_COMMIT_SOCKET=" + controller.path, "WEAVER_TEST_COMMIT_CUT=" + cut})
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	controller.await(t, ctx, "Boot", 0)
	type result struct {
		frames int
		err    error
	}
	done := make(chan result, 1)
	go func() {
		count := 0
		_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { count++; return nil })
		done <- result{count, err}
	}()
	event := controller.await(t, ctx, phase, marker)
	if mode == "control" {
		resumeCommit(t, event, 'c')
	} else if mode == "rollback-before" {
		resumeCommit(t, event, 'r')
	} else if mode == "lost-after" {
		resumeCommit(t, event, 'l')
	} else {
		if err := f.child.Process.Kill(); err != nil {
			t.Fatal(err)
		}
		select {
		case <-f.exited:
		case <-ctx.Done():
			t.Fatal("fault did not terminate original owner")
		}
		f.child = nil
		f.client.Connection.Close()
		f.admin.Connection.Close()
		event.socket.Close()
	}
	select {
	case r := <-done:
		if mode == "control" {
			if r.err != nil || r.frames != 5 {
				t.Fatal("positive lifecycle control", r)
			}
		} else if r.err == nil || r.frames != 0 {
			t.Fatal("unconfirmed consumption emitted frames", r)
		}
	case <-ctx.Done():
		t.Fatal("old worker did not end")
	}
	expected := "unknown"
	if before {
		expected = "queued"
	}
	if mode == "control" {
		expected = "complete"
	}
	if f.child != nil {
		assertNoFaultWorkerUnwind(t, f)
		f.stop(t)
	}
	f.start(t)
	controller.await(t, ctx, "Boot", marker)
	receipt := inspect(t, f)
	if receipt.State != expected || receipt.Held != 4 {
		t.Fatal("restart changed original claim/hold", receipt)
	}
	if before {
		// The known-absent consume may proceed using the retained original hold.
		// The test observer is armed again after restart; resume its exact old cut.
		retry := make(chan error, 1)
		go func() {
			_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
			retry <- err
		}()
		resumed := controller.await(t, ctx, phase, 0)
		resumeCommit(t, resumed, 'c')
		select {
		case err := <-retry:
			if err != nil {
				t.Fatal("known-absent original did not resume", err)
			}
		case <-ctx.Done():
			t.Fatal("resume stalled")
		}
	} else {
		calls := int64(0)
		if mode == "control" {
			calls = 1
		}
		originalStillSpentWithCalls(t, f, receipt, calls)
	}
	want := int64(0)
	if before || mode == "control" {
		want = 1
	}
	if f.primary.Load() != want || f.backup.Load() != 0 {
		t.Fatal("lifecycle recovery duplicated/substituted provider", f.primary.Load(), f.backup.Load(), want)
	}
	if inspect(t, f).Held != 4 {
		t.Fatal("observation released unknown budget")
	}
	f.stop(t)
}
