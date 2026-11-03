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

// A real provider consumes the entire request before withholding headers. Even
// this stronger remote observation is not a receipt exposed by our SDK. Fresh
// authority cannot commit during the current conservative invocation guard;
// after it commits no row may use that old invocation's context.
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
			t.Fatal("authority escaped invocation guard before headers", err)
		case <-time.After(time.Duration(20+selector%11) * time.Millisecond):
		}
		releaseHeaders.Do(func() { close(headers) })
		select {
		case err := <-published:
			if err != nil {
				t.Fatal(err)
			}
		case <-ctx.Done():
			t.Fatal("publication did not complete", ctx.Err())
		}
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
		f.stop(t)
		return true
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 8, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}
