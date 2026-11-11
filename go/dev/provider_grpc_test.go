// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"net/http"
	"slices"
	"sync"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
)

func execute(t *testing.T, f *fixture, encoding pb.Encoding, rows uint32) (*pb.ProviderReceipt, []*pb.Event, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	var events []*pb.Event
	receipt, err := f.client.Execute(ctx, f.plan, encoding, rows, func(event *pb.Event) error { events = append(events, event); return nil })
	return receipt, events, err
}
func inspect(t *testing.T, f *fixture) *pb.ProviderReceipt {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	receipt, err := f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: "f", Node: "infer"})
	if err != nil {
		t.Fatal(err)
	}
	return receipt
}
func TestProviderGRPCStreamingAndArrowOption(t *testing.T) {
	for _, encoding := range []pb.Encoding{pb.Encoding_PROTOBUF, pb.Encoding_ARROW_IPC} {
		t.Run(encoding.String(), func(t *testing.T) {
			f := newFixture(t, completeSSE, false)
			rows := uint32(1)
			if encoding == pb.Encoding_ARROW_IPC {
				rows = 2
			}
			receipt, events, err := execute(t, f, encoding, rows)
			if err != nil {
				t.Fatal(err)
			}
			text := ""
			for _, event := range events {
				text += event.Text
			}
			if text != "hello world" || len(events) != 5 || receipt.Held != 4 || receipt.Reserved != 4 || receipt.Target != "primary" {
				t.Fatalf("unexpected stream: %q events=%d receipt=%v", text, len(events), receipt)
			}
			if f.primary.Load() != 1 || f.backup.Load() != 0 || f.denied.Load() != 0 {
				t.Fatal("pre-dispatch routing or Policy failed")
			}
			if _, _, err := execute(t, f, encoding, rows); err == nil {
				t.Fatal("completed invocation was replayed")
			}
			if f.primary.Load() != 1 || inspect(t, f).Held != 4 {
				t.Fatal("retry duplicated invocation or hold")
			}
		})
	}
}

func TestProviderCallerRouteMutationCannotChangeActiveStream(t *testing.T) {
	for _, encoding := range []pb.Encoding{pb.Encoding_PROTOBUF, pb.Encoding_ARROW_IPC} {
		t.Run(encoding.String(), func(t *testing.T) {
			f := newFixture(t, completeSSE, false)
			original := f.plan
			original.Routes = slices.Clone(f.plan.Routes)
			rows := uint32(1)
			if encoding == pb.Encoding_ARROW_IPC {
				rows = 2
			}
			ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
			defer cancel()
			mutated := false
			receipt, err := f.client.Execute(ctx, f.plan, encoding, rows, func(event *pb.Event) error {
				if !mutated {
					f.plan.Routes[0].Target = "changed"
					f.plan.Routes[0].Endpoint = "https://changed.invalid/v1/chat/completions"
					mutated = true
				}
				return nil
			})
			if err != nil || !mutated || receipt.Target != "primary" || receipt.Held != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
				t.Fatal("active stream followed caller routing storage", receipt, err)
			}
			f.plan = original
			if _, _, err := execute(t, f, encoding, rows); err == nil {
				t.Fatal("caller mutation reopened the original operation")
			}
			if f.primary.Load() != 1 || f.backup.Load() != 0 || inspect(t, f).Held != 4 {
				t.Fatal("original retry duplicated dispatch or released its hold")
			}
		})
	}
}
func TestProviderFailuresNeverRetryOrFallback(t *testing.T) {
	cases := map[string]http.HandlerFunc{
		"redirect": func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Location", "https://localhost:1/forged")
			w.WriteHeader(307)
		},
		"overload": func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(503) },
		"partial-sse": func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			emitChunk(w, "prefix", false)
		},
		"tool-proposal": func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "data: {\"id\":\"stream-1\",\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[]},\"finish_reason\":null}]}\n\n")
		},
	}
	for name, handler := range cases {
		t.Run(name, func(t *testing.T) {
			f := newFixture(t, handler, false)
			_, _, failure := execute(t, f, pb.Encoding_PROTOBUF, 1)
			if failure == nil {
				t.Fatal("indeterminate provider call succeeded")
			}
			// The partial upstream response must terminate with Rust's gRPC
			// failure status, rather than clean EOF or a client decode error.
			if name == "partial-sse" && status.Code(failure) != codes.FailedPrecondition {
				t.Fatalf("terminal gRPC status lost: %v", failure)
			}
			if f.primary.Load() != 1 || f.backup.Load() != 0 || f.denied.Load() != 0 {
				t.Fatal("failure caused a retry or fallback")
			}
			f.plan.Revision = 0
			if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil {
				t.Fatal("spent original operation was retried")
			}
			receipt := inspect(t, f)
			if receipt.State != "unknown" || receipt.Held != 4 || f.primary.Load() != 1 {
				t.Fatal("unknown state or hold was reset")
			}
		})
	}
}
func partialRequestDisconnect(w http.ResponseWriter, r *http.Request) {
	buffer := make([]byte, 1)
	_, _ = r.Body.Read(buffer)
	conn, _, err := w.(http.Hijacker).Hijack()
	if err == nil {
		conn.Close()
	}
}
func TestProviderPartialRequestAndRestartRetainUnknownClaim(t *testing.T) {
	f := newFixture(t, partialRequestDisconnect, true)
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil {
		t.Fatal("partial request outcome accepted")
	}
	if inspect(t, f).State != "unknown" || f.backup.Load() != 0 {
		t.Fatal("partial request caused fallback")
	}
	f.stop(t)
	f.start(t)
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil {
		t.Fatal("restart reopened spent invocation")
	}
	if inspect(t, f).Held != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatal("restart duplicated effect or released budget")
	}
}
func TestProviderRevocationDuringSSEStopsNextRelease(t *testing.T) {
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
	first := make(chan struct{}, 1)
	result := make(chan error, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
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
		t.Fatal("first authorized event missing")
	}
	revision := uint64(0)
	if receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "revoke", ExpectedRevision: &revision, Fence: 2, Policy: "forbid(principal,action,resource);", Schema: f.schema}); err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatal(err)
	}
	once.Do(func() { close(proceed) })
	if err := <-result; err == nil {
		t.Fatal("stale release passed")
	}
	if len(events) != 1 || events[0].Text != "prefix" || inspect(t, f).Held != 4 || f.backup.Load() != 0 {
		t.Fatal("revoked stream released tail or refunded")
	}
	f.plan.Revision = 1
	f.plan.Fence = 2
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil {
		t.Fatal("new authority reopened consumed operation")
	}
	if f.primary.Load() != 1 {
		t.Fatal("new fence duplicated provider call")
	}
}
func TestProviderArrowChecksEveryRow(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	revision := uint64(0)
	policy := f.policy + "\nforbid(principal, action == Weaver::Action::\"emitProvider\", resource) when { context.sequence >= 1 };"
	if receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "row-deny", ExpectedRevision: &revision, Fence: 2, Policy: policy, Schema: f.schema}); err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatal(err)
	}
	f.plan.Revision = 1
	f.plan.Fence = 2
	if _, events, err := execute(t, f, pb.Encoding_ARROW_IPC, 2); err == nil || len(events) != 0 {
		t.Fatal("Arrow batch bypassed per-row Policy")
	}
	if inspect(t, f).Held != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatal("denied batch changed invocation or hold")
	}
}
func TestProviderConcurrentRPCDuplicatesInvokeOnce(t *testing.T) {
	release := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	entered := make(chan struct{}, 1)
	f := newFixture(t, func(w http.ResponseWriter, r *http.Request) { entered <- struct{}{}; <-release; completeSSE(w, r) }, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	outcomes := make(chan error, 2)
	for range 2 {
		go func() {
			_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
			outcomes <- err
		}()
	}
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal("provider not entered")
	}
	once.Do(func() { close(release) })
	failures := 0
	for range 2 {
		if <-outcomes != nil {
			failures++
		}
	}
	if failures != 1 || f.primary.Load() != 1 || inspect(t, f).Held != 4 {
		t.Fatal("duplicate RPC duplicated invocation or reservation")
	}
}
func TestProviderRPCIdentityAndCancellation(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// An operation credential cannot publish authority, even over approved mTLS.
	if _, err := f.client.RPC.PublishAuthority(f.client.Context(ctx), &pb.PublishRequest{Policy: f.policy, Schema: f.schema, Fence: 1}); err == nil {
		t.Fatal("agent became source publisher")
	}
	clone := *f.client
	clone.Token = "wrong-token"
	if _, err := clone.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("wrong token accepted")
	}
	// A different certificate with the same subject is still a different workload key.
	other := secondaryClient(t, f.pki)
	wrong, err := gatewayclient.Dial(ctx, f.address, ownerToken, &tls.Config{RootCAs: f.pki.root, Certificates: []tls.Certificate{other}, ServerName: "localhost"})
	if err != nil {
		t.Fatal(err)
	}
	defer wrong.Connection.Close()
	if _, err := wrong.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("same-subject workload impersonated owner")
	}
	if f.primary.Load() != 0 {
		t.Fatal("unauthorized RPC reached provider")
	}
	forged := f.plan
	forged.Profile = "forged-profile"
	if _, err := f.client.Execute(ctx, forged, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("forged source profile admitted")
	}
	if f.primary.Load() != 0 {
		t.Fatal("forged scope reached provider")
	}
}
func TestProviderClientCancellationCannotReplay(t *testing.T) {
	proceed := make(chan struct{})
	defer close(proceed)
	f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		emitChunk(w, "prefix", false)
		<-proceed
		emitChunk(w, "", true)
		fmt.Fprint(w, "data: [DONE]\n\n")
	}, false)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stopped := errors.New("consumer stopped")
	if _, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return stopped }); !errors.Is(err, stopped) {
		t.Fatal("consumer cancellation lost")
	}
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil {
		t.Fatal("cancelled call retried")
	}
	if inspect(t, f).Held != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatal("cancellation duplicated call or released hold")
	}
}

func TestProviderAuthenticationPrecedesRPCBodyDecode(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	wrong := *f.client
	wrong.Token = "wrong-token"
	stream, err := f.client.Connection.NewStream(wrong.Context(ctx), &grpc.StreamDesc{ServerStreams: true}, pb.Gateway_ExecuteProvider_FullMethodName)
	if err == nil {
		err = stream.RecvMsg(new(pb.ProviderFrame))
	}
	if status.Code(err) != codes.Unauthenticated {
		t.Fatalf("authentication did not precede incomplete body: %v", err)
	}
	if f.primary.Load() != 0 {
		t.Fatal("unauthenticated partial RPC reached provider")
	}
}
