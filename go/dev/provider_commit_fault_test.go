// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/quick"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
)

type commitCut struct {
	phase  string
	marker int
	socket net.Conn
}
type commitController struct {
	path   string
	events chan commitCut
}

func observeCommit(t testing.TB) *commitController {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "weaver-commit-")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "cut.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	o := &commitController{path: path, events: make(chan commitCut, 8)}
	done := make(chan struct{})
	stop := make(chan struct{})
	go func() {
		defer close(done)
		for {
			socket, err := listener.Accept()
			if err != nil {
				return
			}
			_ = socket.SetReadDeadline(time.Now().Add(3 * time.Second))
			line, err := bufio.NewReader(socket).ReadString('\n')
			if err != nil {
				socket.Close()
				return
			}
			var event commitCut
			event.socket = socket
			if _, err = fmt.Sscanf(line, "%s %d", &event.phase, &event.marker); err != nil {
				socket.Close()
				return
			}
			switch event.phase {
			case "Boot", "Mutation", "Stage", "Publish":
				socket.Close()
			}
			select {
			case o.events <- event:
			case <-stop:
				socket.Close()
				return
			}
		}
	}()
	t.Cleanup(func() {
		close(stop)
		listener.Close()
		<-done
		for len(o.events) > 0 {
			(<-o.events).socket.Close()
		}
		os.RemoveAll(directory)
	})
	return o
}
func (o *commitController) await(t testing.TB, ctx context.Context, phase string, marker int) commitCut {
	t.Helper()
	select {
	case event := <-o.events:
		if event.phase != phase || event.marker != marker {
			t.Fatalf("native persisted cut: got %s/%d want %s/%d", event.phase, event.marker, phase, marker)
		}
		t.Logf("native recovered/independent observation phase=%s dispatched=%d", event.phase, event.marker)
		return event
	case <-ctx.Done():
		t.Fatal("missing native commit cut", phase, ctx.Err())
		return commitCut{}
	}
}
func resumeCommit(t testing.TB, event commitCut, command byte) {
	t.Helper()
	if _, err := event.socket.Write([]byte{command}); err != nil {
		t.Fatal(err)
	}
	event.socket.Close()
}

// Kill/wait alone is insufficient: a worker can unwind its transaction while
// the server stays alive, and a later kill would mask a Drop-based rollback.
func assertNoFaultWorkerUnwind(t testing.TB, f *fixture) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "panicked at") {
		t.Fatalf("worker unwound before crash/fault acceptance: %s", data)
	}
}

// Every fault is reached after real TLS request seal. The commit cut surrounds
// the actual native commit, not the client RPC reply. Crashes are subprocess
// kills: no Rust Drop, unwind, or cleanup can manufacture the recovery witness.
func TestProviderSealedTursoCommitRecovery(t *testing.T) {
	for _, journal := range []string{"wal", "mvcc"} {
		t.Run(journal, func(t *testing.T) {
			t.Setenv("WEAVER_STORAGE_JOURNAL", journal)
			for _, mode := range []string{"control", "rollback", "crash-before", "lost-ack", "crash-after", "late-allow", "late-revoke"} {
				t.Run(mode, func(t *testing.T) {
					check := func(selector uint8) bool {
						controller := observeCommit(t)
						cut, phase, marker := "after", "AfterCommit", 2
						if mode == "rollback" || mode == "crash-before" {
							cut, phase, marker = "before", "BeforeCommit", 1
						}
						f := fixtureWithInvocation(t, func(w http.ResponseWriter, r *http.Request) {
							if _, err := io.Copy(io.Discard, r.Body); err != nil {
								t.Error(err)
								return
							}
							completeSSE(w, r)
						}, true, observedServer(t), []string{"--exact", "provider_commit_tests::serve_observed_gateway", "--ignored", "--nocapture"}, []string{"WEAVER_TEST_COMMIT_SOCKET=" + controller.path, "WEAVER_TEST_COMMIT_CUT=" + cut})
						ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
						defer cancel()
						controller.await(t, ctx, "Boot", 0)
						encoding, rows := pb.Encoding_PROTOBUF, uint32(1)
						if selector&1 != 0 {
							encoding, rows = pb.Encoding_ARROW_IPC, 2
						}
						type result struct {
							events int
							err    error
						}
						finished := make(chan result, 1)
						go func() {
							count := 0
							_, err := f.client.Execute(ctx, f.plan, encoding, rows, func(*pb.Event) error { count++; return nil })
							finished <- result{count, err}
						}()
						event := controller.await(t, ctx, phase, marker)
						if mode == "late-allow" || mode == "late-revoke" {
							revision := uint64(0)
							policy := f.policy
							if mode == "late-revoke" {
								policy = "forbid(principal,action,resource);"
							}
							receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "during-native-ack", ExpectedRevision: &revision, Fence: 2, Policy: policy, Schema: f.schema})
							if err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
								t.Fatal("new fence did not commit before old worker resumed", receipt, err)
							}
							resumeCommit(t, event, 'c')
						} else if mode == "control" {
							resumeCommit(t, event, 'c')
						} else if mode == "rollback" {
							resumeCommit(t, event, 'r')
						} else if mode == "lost-ack" {
							resumeCommit(t, event, 'l')
						} else {
							if err := f.child.Process.Kill(); err != nil {
								t.Fatal(err)
							}
							select {
							case err := <-f.exited:
								if err == nil {
									t.Fatal("fault did not crash process")
								}
							case <-ctx.Done():
								t.Fatal("crash process did not exit")
							}
							f.child = nil
							f.client.Connection.Close()
							f.admin.Connection.Close()
							event.socket.Close()
						}
						select {
						case outcome := <-finished:
							if (mode == "control" && (outcome.err != nil || outcome.events != 5)) || (mode != "control" && (outcome.err == nil || outcome.events != 0)) {
								t.Fatal("unobserved/stale native commit emitted response", outcome)
							}
						case <-ctx.Done():
							t.Fatal("old RPC did not end", ctx.Err())
						}
						assertNoFaultWorkerUnwind(t, f)
						expectedState, expectedEvents := "unknown", uint64(0)
						if mode == "control" {
							expectedState, expectedEvents = "complete", 5
						}
						if f.child != nil {
							before := inspect(t, f)
							if before.Held != 4 || before.State != expectedState || before.Events != expectedEvents {
								t.Fatal("unknown exposure changed", before)
							}
							f.stop(t)
						}
						f.start(t)
						controller.await(t, ctx, "Boot", marker)
						receipt := inspect(t, f)
						if receipt.State != expectedState || receipt.Held != 4 || receipt.Events != expectedEvents {
							t.Fatal("recovery released unknown exposure", receipt)
						}
						originalStillSpent(t, f, receipt)
						if mode == "late-allow" || mode == "late-revoke" {
							f.plan.Revision, f.plan.Fence = 1, 2
							originalStillSpent(t, f, receipt)
						}
						if f.primary.Load() != 1 || f.backup.Load() != 0 {
							t.Fatal("native fault duplicated/fell back", f.primary.Load(), f.backup.Load())
						}
						f.stop(t)
						return true
					}
					if err := quick.Check(check, &quick.Config{MaxCount: 2, Rand: rand.New(rand.NewSource(293))}); err != nil {
						t.Fatal(err)
					}
				})
			}
		})
	}
}
