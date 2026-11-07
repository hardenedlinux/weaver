// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

const observedServerTest = "grpc_output::backpressure_tests::serve_observed_gateway"

var observedBuild struct {
	sync.Once
	binary string
	err    error
}

func observedServer(t testing.TB) string {
	t.Helper()
	observedBuild.Do(func() {
		cmd := exec.Command("cargo", "test", "-p", "weaver-server", "--lib", "--features", "arrow", "--locked", "--offline", "--no-run", "--message-format=json")
		cmd.Dir = root(t)
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		var err error
		built, err := buildCargoExecutable(cmd, cargoTarget{Name: "weaver_server", Kind: "lib", Test: true})
		if err == nil {
			observedBuild.binary = filepath.Join(filepath.Dir(serverBinary), "weaver-observed")
			var digest string
			digest, err = publishProviderImage(built, observedBuild.binary)
			if err == nil {
				t.Logf("observed provider image sha256=%s", digest)
			}
		}
		if err != nil {
			observedBuild.err = fmt.Errorf("observed test build: %w: %s", err, stderr.String())
		}
	})
	if observedBuild.err != nil {
		t.Fatal(observedBuild.err)
	}
	return observedBuild.binary
}

type flowEvent struct {
	phase           string
	id, first, rows uint64
}
type flowObserver struct {
	events chan flowEvent
	path   string
}

func observeFlow(t *testing.T) *flowObserver {
	t.Helper()
	directory, err := os.MkdirTemp("/tmp", "weaver-flow-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(directory) })
	path := filepath.Join(directory, "flow.sock")
	socket, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: path, Net: "unixgram"})
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Chmod(path, 0600); err != nil {
		socket.Close()
		t.Fatal(err)
	}
	observer := &flowObserver{events: make(chan flowEvent, 512), path: path}
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		var data [256]byte
		for {
			n, _, err := socket.ReadFromUnix(data[:])
			if err != nil {
				return
			}
			fields := strings.Fields(string(data[:n]))
			if len(fields) != 4 {
				return
			}
			id, e1 := strconv.ParseUint(fields[1], 10, 64)
			first, e2 := strconv.ParseUint(fields[2], 10, 64)
			rows, e3 := strconv.ParseUint(fields[3], 10, 64)
			if e1 != nil || e2 != nil || e3 != nil {
				return
			}
			select {
			case observer.events <- flowEvent{fields[0], id, first, rows}:
			case <-stop:
				return
			}
		}
	}()
	t.Cleanup(func() { close(stop); socket.Close(); <-done })
	return observer
}
func (o *flowObserver) await(t *testing.T, ctx context.Context, phase string, id uint64) flowEvent {
	t.Helper()
	for {
		select {
		case event := <-o.events:
			if phase == "ready" && event.id == id && (event.phase == "expired" || event.phase == "cancelled") {
				t.Fatalf("reservation %d ended as %s before required capacity wake; the existing native deadline and assertions remain unchanged", id, event.phase)
			}
			if event.phase == phase && (id == 0 || event.id == id) {
				t.Logf("actual output phase=%s wait=%d first=%d rows=%d", event.phase, event.id, event.first, event.rows)
				return event
			}
		case <-ctx.Done():
			t.Fatalf("missing actual output phase %s: %v", phase, ctx.Err())
		}
	}
}
func pressuredSSE(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	for i := 0; i < 48; i++ {
		select {
		case <-r.Context().Done():
			return
		default:
		}
		emitChunk(w, fmt.Sprintf("%04d:%s", i, strings.Repeat("x", 48*1024-5)), false)
	}
	emitChunk(w, "", true)
	fmt.Fprint(w, "data: [DONE]\n\n")
}
func observedFixture(t *testing.T, pause bool) (*fixture, *flowObserver) {
	t.Helper()
	observer := observeFlow(t)
	env := []string{"WEAVER_TEST_FLOW_EVENTS=" + observer.path}
	if pause {
		env = append(env, "WEAVER_TEST_PAUSE_AFTER_WAITED_ENQUEUE=1")
	}
	f := fixtureWithInvocation(t, pressuredSSE, false, observedServer(t), []string{"--exact", observedServerTest, "--ignored", "--nocapture"}, env)
	return f, observer
}
func slowStream(t *testing.T, ctx context.Context, f *fixture, encoding pb.Encoding) (grpc.ServerStreamingClient[pb.ProviderFrame], context.CancelFunc) {
	t.Helper()
	security := &tls.Config{RootCAs: f.pki.root, Certificates: []tls.Certificate{f.pki.client}, ServerName: "localhost", MinVersion: tls.VersionTLS13}
	connection, err := grpc.DialContext(ctx, f.address, grpc.WithBlock(), grpc.WithTransportCredentials(credentials.NewTLS(security)), grpc.WithDisableRetry(),
		grpc.WithStaticStreamWindowSize(64*1024), grpc.WithStaticConnWindowSize(64*1024), grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(4*1024*1024)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { connection.Close() })
	streamCtx, cancel := context.WithCancel(ctx)
	t.Cleanup(cancel)
	rows := uint32(1)
	if encoding == pb.Encoding_ARROW_IPC {
		rows = 2
	}
	stream, err := pb.NewGatewayClient(connection).ExecuteProvider(f.client.Context(streamCtx), &pb.ProviderRequest{Plan: gatewayclient.Plan(f.plan), Encoding: encoding, BatchRows: rows})
	if err != nil {
		t.Fatal(err)
	}
	return stream, cancel
}

type drained struct {
	count uint64
	done  bool
	err   error
}

func drainStream(stream grpc.ServerStreamingClient[pb.ProviderFrame], encoding pb.Encoding) drained {
	var result drained
	for {
		frame, err := stream.Recv()
		if err == io.EOF {
			return result
		}
		if err != nil {
			result.err = err
			return result
		}
		events, err := gatewayclient.Events(frame, encoding)
		if err != nil {
			result.err = err
			return result
		}
		for _, event := range events {
			if event.Sequence != result.count {
				result.err = errors.New("repeated or missing sequence")
				return result
			}
			result.count++
			result.done = event.Kind == "done"
		}
	}
}
func originalStillSpent(t *testing.T, f *fixture, before *pb.ProviderReceipt) {
	t.Helper()
	originalStillSpentWithCalls(t, f, before, 1)
}

func originalStillSpentWithCalls(t *testing.T, f *fixture, before *pb.ProviderReceipt, calls int64) {
	t.Helper()
	if _, _, err := execute(t, f, pb.Encoding_ARROW_IPC, 2); err == nil {
		t.Fatal("reconnected RPC reopened original claim")
	}
	after := inspect(t, f)
	if after.Digest != before.Digest || after.Events != before.Events || after.Held != 4 || after.State != before.State || after.Reserved != before.Reserved || after.Target != before.Target || f.primary.Load() != calls || f.backup.Load() != 0 {
		t.Fatalf("original outcome changed: before=%v after=%v calls=%d", before, after, f.primary.Load())
	}
}

func TestProviderSlowConsumerPolicyChangeDuringCapacityWait(t *testing.T) {
	for _, encoding := range []pb.Encoding{pb.Encoding_PROTOBUF, pb.Encoding_ARROW_IPC} {
		t.Run(encoding.String(), func(t *testing.T) {
			f, observer := observedFixture(t, false)
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			defer cancel()
			stream, _ := slowStream(t, ctx, f, encoding)
			pending := observer.await(t, ctx, "pending", 0) // No Recv has returned HTTP/2 credit.
			before := inspect(t, f)
			revision := uint64(0)
			result, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "slow-revoke", ExpectedRevision: &revision, Fence: 2, Policy: "forbid(principal,action,resource);", Schema: f.schema})
			if err != nil || result.GetOutcome() != pb.PublicationOutcome_COMMITTED {
				t.Fatalf("source commit while output blocked: %v %v", result, err)
			}
			finished := make(chan drained, 1)
			go func() { finished <- drainStream(stream, encoding) }()
			observer.await(t, ctx, "ready", pending.id) // Actual reservation wakes only after revoke committed.
			out := <-finished
			after := inspect(t, f)
			if out.done || out.count > before.Events || after.Events != before.Events || after.Held != 4 {
				t.Fatalf("stale release after capacity wake: output=%+v before=%v after=%v", out, before, after)
			}
			// A later allow still cannot reopen the consumed root under a fresh RPC.
			revision = 1
			if result, err = f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "slow-restore", ExpectedRevision: &revision, Fence: 3, Policy: f.policy, Schema: f.schema}); err != nil || result.GetOutcome() != pb.PublicationOutcome_COMMITTED {
				t.Fatal(err)
			}
			f.plan.Revision = 2
			f.plan.Fence = 3
			originalStillSpent(t, f, after)
		})
	}
}
func TestProviderSlowConsumerCancellationAndReconnectRetainHistory(t *testing.T) {
	f, observer := observedFixture(t, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	stream, stop := slowStream(t, ctx, f, pb.Encoding_ARROW_IPC)
	pending := observer.await(t, ctx, "pending", 0)
	before := inspect(t, f)
	stop()
	observer.await(t, ctx, "cancelled", pending.id)
	_ = drainStream(stream, pb.Encoding_ARROW_IPC)
	originalStillSpent(t, f, before)
}

func TestProviderSlowConsumerRevocationRestartAndRestoredPolicyCannotReopen(t *testing.T) {
	f, observer := observedFixture(t, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	stream, _ := slowStream(t, ctx, f, pb.Encoding_ARROW_IPC)
	pending := observer.await(t, ctx, "pending", 0)
	before := inspect(t, f)
	revision := uint64(0)
	request := &pb.PublishRequest{OperationId: "revoke-before-restart", ExpectedRevision: &revision, Fence: 2, Policy: "forbid(principal,action,resource);", Schema: f.schema}
	publication, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), request)
	if err != nil || publication.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatalf("revocation did not commit: %v %v", publication, err)
	}
	finished := make(chan drained, 1)
	go func() { finished <- drainStream(stream, pb.Encoding_ARROW_IPC) }()
	observer.await(t, ctx, "ready", pending.id)
	out := <-finished
	if out.done || out.count > before.Events {
		t.Fatalf("revocation admitted a later range: %+v", out)
	}
	f.stop(t) // Existing natural-exit gate and complete resource cleanup.
	f.start(t)
	recovered := inspect(t, f)
	if recovered.Digest != before.Digest || recovered.Events != before.Events || recovered.Held != 4 {
		t.Fatalf("consumption/hold changed across recovery: before=%v recovered=%v", before, recovered)
	}
	// Retry the exact original publication after restart, retaining its outcome.
	publication, err = f.admin.RPC.PublishAuthority(f.admin.Context(ctx), request)
	if err != nil || publication.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatalf("publication outcome was not recoverable: %v %v", publication, err)
	}
	revision = 1
	publication, err = f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "restore-after-restart", ExpectedRevision: &revision, Fence: 3, Policy: f.policy, Schema: f.schema})
	if err != nil || publication.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatalf("restored policy failed: %v %v", publication, err)
	}
	f.plan.Revision, f.plan.Fence = 2, 3
	originalStillSpent(t, f, recovered)
}

func TestProviderSlowConsumerPositiveControlCompletesAfterCapacityReturns(t *testing.T) {
	f, observer := observedFixture(t, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	stream, _ := slowStream(t, ctx, f, pb.Encoding_ARROW_IPC)
	pending := observer.await(t, ctx, "pending", 0)
	finished := make(chan drained, 1)
	go func() { finished <- drainStream(stream, pb.Encoding_ARROW_IPC) }()
	observer.await(t, ctx, "ready", pending.id)
	out := <-finished
	if out.err != nil || !out.done || out.count != 50 {
		t.Fatalf("positive control failed: %+v", out)
	}
	receipt := inspect(t, f)
	if receipt.State != "complete" || receipt.Events != 50 || receipt.Held != 4 || f.primary.Load() != 1 {
		t.Fatal(receipt)
	}
}
func TestProviderSlowConsumerEnqueueBeforeCommitCrashCannotReplayPendingRange(t *testing.T) {
	f, observer := observedFixture(t, true)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	stream, _ := slowStream(t, ctx, f, pb.Encoding_ARROW_IPC)
	observer.await(t, ctx, "pending", 0)
	finished := make(chan drained, 1)
	go func() { finished <- drainStream(stream, pb.Encoding_ARROW_IPC) }()
	fault := observer.await(t, ctx, "fault-window", 0)
	if err := f.child.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-f.exited:
		if err == nil {
			t.Fatal("crash injection did not kill the test server")
		}
	case <-ctx.Done():
		t.Fatal("crash process did not exit")
	}
	f.child = nil
	f.client.Connection.Close()
	f.admin.Connection.Close()
	<-finished
	assertNoFaultWorkerUnwind(t, f)
	f.start(t)
	receipt := inspect(t, f)
	if receipt.Events != fault.first+fault.rows || receipt.Held != 4 || receipt.State == "complete" {
		t.Fatalf("pending enqueue outcome lost: fault=%+v receipt=%v", fault, receipt)
	}
	originalStillSpent(t, f, receipt)
}
