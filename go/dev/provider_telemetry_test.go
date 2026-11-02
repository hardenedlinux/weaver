//go:build integration && !windows

package dev

import (
	"context"
	"fmt"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"net/http"
	"testing"
	"testing/quick"
	"time"
)

func TestProviderTelemetryCannotRefundOrRedispatchUnknownSend(t *testing.T) {
	f := newFixture(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"prefix\"}}]}\n\n")
		w.(http.Flusher).Flush() // Missing completion makes usage/dispatch uncertain.
	}, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if _, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("partial response unexpectedly completed")
	}
	key := &pb.OperationKey{Family: "f", Node: "infer"}
	before, err := f.client.RPC.Inspect(f.client.Context(ctx), key)
	if err != nil || before.GetHeld() != 4 {
		t.Fatalf("original unknown hold: %v %v", before, err)
	}
	property := func(reads uint8) bool {
		for range int(reads%8 + 1) {
			metrics, err := f.admin.RPC.InspectTelemetry(f.admin.Context(ctx), &pb.Empty{})
			if err != nil || metrics.GetProviderAdmitted() != 1 || metrics.GetSnapshotReads() == 0 {
				return false
			}
		}
		after, err := f.client.RPC.Inspect(f.client.Context(ctx), key)
		return err == nil && proto.Equal(before, after) && f.primary.Load() == 1 && f.backup.Load() == 0
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 16}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.client.RPC.InspectTelemetry(f.client.Context(ctx), &pb.Empty{}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("operation ingress read source statistics: %v", err)
	}
	f.stop(t)
	f.start(t)
	metrics, err := f.admin.RPC.InspectTelemetry(f.admin.Context(ctx), &pb.Empty{})
	if err != nil || metrics.GetProviderAdmitted() != 0 {
		t.Fatalf("process-local restart: %v %v", metrics, err)
	}
	if _, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("reset telemetry restored original execution")
	}
	after, err := f.client.RPC.Inspect(f.client.Context(ctx), key)
	if err != nil || after.GetHeld() != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatalf("telemetry restart refunded or repeated send: %v %v", after, err)
	}
}

func TestProviderControlTelemetryObservesBothServices(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	c := newControlProcess(t, f, writeControlBundle(t, f, controlBundle(t, f), "json"))
	c.start(t)
	t.Cleanup(func() { c.stop(t) })
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	bundle := controlBundle(t, f)
	if _, err := c.client.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err != nil {
		t.Fatal(err)
	}
	control, err := c.client.RPC.InspectTelemetry(c.client.Context(ctx), &pb.Empty{})
	if err != nil || control.GetProviderCompleted() != 1 || control.GetResponseFramesQueued() == 0 {
		t.Fatalf("control observations: %v %v", control, err)
	}
	authority, err := f.admin.RPC.InspectTelemetry(f.admin.Context(ctx), &pb.Empty{})
	if err != nil || authority.GetProviderAdmitted() != 1 || authority.GetResponseFramesQueued() == 0 || f.primary.Load() != 1 {
		t.Fatalf("authority observations: %v %v", authority, err)
	}
}
