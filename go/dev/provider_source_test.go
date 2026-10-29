//go:build integration && !windows

package dev

import (
	"context"
	"crypto/tls"
	"net"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestProviderSourceIngressBindsCertificateCredentialAndMethod(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cases := []struct {
		name, address, token string
		certificate          tls.Certificate
	}{
		{"forwarded-source-token", f.sourceAddress, adminToken, f.pki.client},
		{"operation-token-with-source-key", f.sourceAddress, ownerToken, f.pki.source},
		{"source-key-on-operation-ingress", f.address, ownerToken, f.pki.source},
		{"source-token-on-operation-ingress", f.address, adminToken, f.pki.client},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			security := connectionTLS(f)
			security.Certificates = []tls.Certificate{test.certificate}
			client, err := gatewayclient.Dial(ctx, test.address, test.token, security)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Connection.Close()
			revision := uint64(0)
			_, err = client.RPC.PublishAuthority(client.Context(ctx), &pb.PublishRequest{OperationId: "forged", ExpectedRevision: &revision, Fence: 2, Policy: "forbid(principal,action,resource);", Schema: f.schema})
			if status.Code(err) != codes.Unauthenticated {
				t.Fatalf("cross-ingress identity accepted: %v", err)
			}
		})
	}
	// Even valid ingress credentials cannot select methods assigned to the other role.
	if _, err := f.client.RPC.PublishAuthority(f.client.Context(ctx), &pb.PublishRequest{Policy: f.policy, Schema: f.schema, Fence: 2}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("operation ingress exposed publication: %v", err)
	}
	stream, err := f.admin.RPC.ExecuteProvider(f.admin.Context(ctx), &pb.ProviderRequest{Plan: gatewayclient.Plan(f.plan), Encoding: pb.Encoding_PROTOBUF, BatchRows: 1})
	if err == nil {
		_, err = stream.Recv()
	}
	if status.Code(err) != codes.PermissionDenied {
		t.Fatalf("source ingress exposed execution: %v", err)
	}
	if _, err := f.admin.RPC.Inspect(f.admin.Context(ctx), &pb.OperationKey{Family: "f", Node: "infer"}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("source ingress exposed operation query: %v", err)
	}
	if f.primary.Load() != 0 {
		t.Fatal("cross-role call reached provider")
	}
	revision := uint64(0)
	if receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "source-update", ExpectedRevision: &revision, Fence: 2, Policy: f.policy, Schema: f.schema}); err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatalf("rejected identity changed authority: %v", err)
	}
	f.plan.Revision, f.plan.Fence = 1, 2
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err != nil {
		t.Fatal(err)
	}
	if f.primary.Load() != 1 {
		t.Fatal("valid ingress did not preserve original attempt")
	}
}

func TestProviderSourceConnectionBudgetCannotBorrowOperationCapacity(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	security := connectionTLS(f)
	security.Certificates = []tls.Certificate{f.pki.source}
	var idle []*tls.Conn
	t.Cleanup(func() {
		for _, conn := range idle {
			conn.Close()
		}
	})
	for range 3 {
		conn, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp4", f.sourceAddress, security)
		if err != nil {
			t.Fatal(err)
		}
		idle = append(idle, conn)
	}
	blockedHandshakeAt(t, f.sourceAddress, security)
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err != nil {
		t.Fatalf("source connection pressure consumed operation capacity: %v", err)
	}
	if receipt := inspect(t, f); receipt.Held != 4 {
		t.Fatalf("source saturation changed held budget: %v", receipt)
	}
}
