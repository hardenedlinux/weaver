//go:build integration && !windows

package dev

import (
	"context"
	"fmt"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"testing"
	"time"
)

// BenchmarkGatewayInspect measures the real warm mTLS gRPC owner boundary.
// Reported allocations belong to the Go client, not the remote Rust process.
func BenchmarkGatewayInspect(b *testing.B) {
	f := newFixture(b, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		receipt, err := f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: "f", Node: "infer"})
		if err != nil || receipt.State != "complete" || receipt.Held != 4 {
			b.Fatalf("read-only benchmark changed canonical outcome: %v", err)
		}
	}
}

// BenchmarkGatewayInspectReconnect includes a new TCP/mTLS/HTTP2 connection and
// actual canonical read per iteration. It is distinct from warm RPC latency.
func BenchmarkGatewayInspectReconnect(b *testing.B) {
	f := newFixture(b, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err != nil {
		b.Fatal(err)
	}
	security := connectionTLS(f)
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		client, err := gatewayclient.Dial(ctx, f.address, ownerToken, security)
		if err != nil {
			b.Fatal(err)
		}
		receipt, readError := client.RPC.Inspect(client.Context(ctx), &pb.OperationKey{Family: "f", Node: "infer"})
		closeError := client.Connection.Close()
		if readError != nil || closeError != nil || receipt.State != "complete" || receipt.Held != 4 {
			b.Fatalf("reconnect changed canonical outcome: %v %v", readError, closeError)
		}
	}
}

// BenchmarkGatewayAuthorityPublish measures authenticated typed Policy publication
// and its durable source CAS. Commit never invokes an external provider.
func BenchmarkGatewayAuthorityPublish(b *testing.B) {
	f := newFixture(b, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	revision := uint64(0)
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		result, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: fmt.Sprintf("bench-%d", revision), ExpectedRevision: &revision, Fence: 1, Policy: f.policy, Schema: f.schema})
		if err != nil || result.GetOutcome() != pb.PublicationOutcome_COMMITTED || result.GetRevision() != revision+1 {
			b.Fatalf("source publication CAS failed: %v", err)
		}
		revision = result.GetRevision()
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 || f.denied.Load() != 0 {
		b.Fatal("source commit triggered external execution")
	}
}
