//go:build integration && !windows

package dev

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// Test-only mTLS relay loses the successful source reply after forwarding one RPC.
type publicationReplyLoss struct {
	pb.UnimplementedGatewayServer
	source *gatewayclient.Client
	calls  atomic.Int64
}

func (s *publicationReplyLoss) PublishAuthority(ctx context.Context, p *pb.PublishRequest) (*pb.PublicationReceipt, error) {
	s.calls.Add(1)
	if _, err := s.source.RPC.PublishAuthority(s.source.Context(ctx), p); err != nil {
		return nil, err
	}
	return nil, status.Error(codes.Unavailable, "injected reply loss after durable decision")
}

func TestProviderPublicationLostReplyRestartAndHistoricalDecision(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err != nil {
		t.Fatal(err)
	}
	certificate, err := tls.X509KeyPair(f.pki.serverPEM, f.pki.serverKey)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	relay := &publicationReplyLoss{source: f.admin}
	server := grpc.NewServer(grpc.Creds(credentials.NewTLS(&tls.Config{Certificates: []tls.Certificate{certificate}, ClientCAs: f.pki.root, ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS13})))
	pb.RegisterGatewayServer(server, relay)
	stopped := make(chan error, 1)
	go func() { stopped <- server.Serve(listener) }()
	t.Cleanup(func() {
		server.Stop()
		if err := <-stopped; err != nil && !errors.Is(err, grpc.ErrServerStopped) {
			t.Error(err)
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	security := connectionTLS(f)
	security.Certificates = []tls.Certificate{f.pki.source}
	client, err := gatewayclient.Dial(ctx, listener.Addr().String(), adminToken, security)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Connection.Close()
	zero := uint64(0)
	original := v1.Publication{OperationID: "lost-result", ExpectedRevision: &zero, Fence: 2, Policy: "forbid(principal,action,resource);", Schema: f.schema}
	if _, err := client.Publish(ctx, original); status.Code(err) != codes.Unavailable {
		t.Fatalf("expected lost result: %v", err)
	}
	if relay.calls.Load() != 1 {
		t.Fatal("SDK retried publication automatically")
	}
	first, err := f.admin.InspectPublication(ctx, original)
	if err != nil || first.GetRevision() != 1 || first.GetFence() != 2 || first.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatalf("lost result not recoverable: %v %v", first, err)
	}
	replay, err := f.admin.Publish(ctx, original)
	if err != nil || !proto.Equal(first, replay) {
		t.Fatalf("exact replay changed result: %v %v", replay, err)
	}
	stale := original
	stale.OperationID = "stale-parent"
	rejected, err := f.admin.Publish(ctx, stale)
	if !errors.Is(err, gatewayclient.ErrPublicationRejected) || rejected.GetOutcome() != pb.PublicationOutcome_REJECTED {
		t.Fatalf("stale parent was rebased: %v %v", rejected, err)
	}
	one := uint64(1)
	later := v1.Publication{OperationID: "later", ExpectedRevision: &one, Fence: 3, Policy: f.policy, Schema: f.schema}
	if r, err := f.admin.Publish(ctx, later); err != nil || r.GetRevision() != 2 {
		t.Fatalf("later policy: %v %v", r, err)
	}
	f.stop(t)
	f.start(t)
	recovered, err := f.admin.InspectPublication(ctx, original)
	if err != nil || !proto.Equal(first, recovered) {
		t.Fatalf("restart changed historical result: %v %v", recovered, err)
	}
	rejectedAgain, err := f.admin.Publish(ctx, stale)
	if !errors.Is(err, gatewayclient.ErrPublicationRejected) || !proto.Equal(rejected, rejectedAgain) {
		t.Fatal("rejected decision was replaced by current head")
	}
	two := uint64(2)
	forged := original
	forged.ExpectedRevision = &two
	if _, err := f.admin.Publish(ctx, forged); err == nil {
		t.Fatal("original ID was rebound")
	}
	absent := original
	absent.OperationID = "not-observed"
	if _, err := f.admin.InspectPublication(ctx, absent); status.Code(err) != codes.NotFound {
		t.Fatalf("absence misclassified: %v", err)
	}
	digest, _ := original.Digest()
	if _, err := f.client.RPC.InspectPublication(f.client.Context(ctx), &pb.PublicationKey{OperationId: original.OperationID, Digest: digest}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("operation ingress exposed publication outcomes: %v", err)
	}
	f.plan.Revision, f.plan.Fence = 2, 3
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil {
		t.Fatal("later policy reopened consumed original claim")
	}
	if receipt := inspect(t, f); receipt.Held != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatalf("publication recovery changed original budget or execution: %v", receipt)
	}
}
