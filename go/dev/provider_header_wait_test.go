//go:build integration && !windows

package dev

import (
	"context"
	"io"
	"math/rand"
	"net/http"
	"sync"
	"testing"
	"testing/quick"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
)

// A real provider drains the request and withholds all response bytes. Authority
// must commit before headers are released: the actual TLS writer is sealed, and
// no old-context response row or recovery replay may become an effect.
func TestProviderHeaderWaitAuthorityBoundary(t *testing.T) {
	check := func(selector uint8) bool {
		drained, headers, body := make(chan struct{}), make(chan struct{}), make(chan struct{})
		var releaseHeaders, releaseBody sync.Once
		unblock := func() { releaseHeaders.Do(func() { close(headers) }); releaseBody.Do(func() { close(body) }) }

		f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
			if _, err := io.Copy(io.Discard, r.Body); err != nil {
				t.Error(err)
				return
			}
			close(drained)
			<-headers
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			<-body
			completeSSE(w, r)
		}, false)
		t.Cleanup(unblock)
		ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
		defer cancel()
		encoding, rows := pb.Encoding_PROTOBUF, uint32(1)
		if selector&1 != 0 {
			encoding, rows = pb.Encoding_ARROW_IPC, 2
		}
		type result struct {
			events int
			err    error
		}
		sent := make(chan result, 1)
		go func() {
			count := 0
			_, err := f.client.Execute(ctx, f.plan, encoding, rows, func(*pb.Event) error { count++; return nil })
			sent <- result{count, err}
		}()
		select {
		case <-drained:
		case <-ctx.Done():
			t.Fatal("request did not drain", ctx.Err())
		}
		published := make(chan error, 1)
		go func() {
			revision := uint64(0)
			policy := f.policy
			if selector&2 != 0 {
				policy = "forbid(principal,action,resource);"
			}
			receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "header-cut", ExpectedRevision: &revision, Fence: 2, Policy: policy, Schema: f.schema})
			if err == nil && receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
				t.Error("publication not committed", receipt)
			}
			published <- err
		}()
		select {
		case err := <-published:
			if err != nil {
				t.Fatal(err)
			}
		case <-ctx.Done():
			t.Fatal("sealed header wait retained the authority guard", ctx.Err())
		}
		time.Sleep(time.Duration(selector%11) * time.Millisecond)
		releaseHeaders.Do(func() { close(headers) })
		releaseBody.Do(func() { close(body) })
		outcome := <-sent
		if outcome.err == nil || outcome.events != 0 || f.primary.Load() != 1 || f.backup.Load() != 0 || inspect(t, f).Held != 4 || inspect(t, f).State != "unknown" {
			t.Fatal("old context escaped response release", outcome, inspect(t, f))
		}
		f.stop(t)
		f.start(t)
		if _, events, err := execute(t, f, encoding, rows); err == nil || len(events) != 0 || f.primary.Load() != 1 || inspect(t, f).Held != 4 {
			t.Fatal("recovery replayed request or refunded unknown hold", err)
		}
		f.plan.Revision, f.plan.Fence = 1, 2
		if _, events, err := execute(t, f, encoding, rows); err == nil || len(events) != 0 || f.primary.Load() != 1 || inspect(t, f).Held != 4 {
			t.Fatal("new authority replayed the spent original request", err)
		}
		f.stop(t)
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 8, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}

// Early headers cannot stand in for completion. In full-duplex mode the peer
// sends headers before draining; partial termination must retain unknown exposure.
func TestProviderEarlyHeadersAndPartialBody(t *testing.T) {
	check := func(selector uint8) bool {
		partial := selector&1 != 0
		f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
			if err := http.NewResponseController(w).EnableFullDuplex(); err != nil {
				t.Error(err)
				return
			}
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			if partial {
				var prefix [1]byte
				_, _ = r.Body.Read(prefix[:])
				conn, _, err := w.(http.Hijacker).Hijack()
				if err == nil {
					conn.Close()
				}
				return
			}
			if _, err := io.Copy(io.Discard, r.Body); err != nil {
				t.Error(err)
				return
			}
			completeSSE(w, r)
		}, true)
		encoding, rows := pb.Encoding_PROTOBUF, uint32(1)
		if selector&2 != 0 {
			encoding, rows = pb.Encoding_ARROW_IPC, 2
		}
		receipt, events, err := execute(t, f, encoding, rows)
		if partial {
			if err == nil || len(events) != 0 || inspect(t, f).State != "unknown" {
				t.Fatal("early headers certified partial request", receipt, events, err)
			}
		} else if err != nil || receipt.State != "complete" || len(events) != 5 {
			t.Fatal("early-header full-duplex control failed", receipt, err)
		}
		if f.primary.Load() != 1 || f.backup.Load() != 0 || inspect(t, f).Held != 4 {
			t.Fatal("early headers changed original exposure")
		}
		f.stop(t)
		f.start(t)
		if _, events, err := execute(t, f, encoding, rows); err == nil || len(events) != 0 || f.primary.Load() != 1 || inspect(t, f).Held != 4 {
			t.Fatal("early-header recovery replayed request or refunded budget", err)
		}
		f.stop(t)
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 8, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}
