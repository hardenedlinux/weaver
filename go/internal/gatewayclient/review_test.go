// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package gatewayclient

import (
	"context"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"google.golang.org/grpc"
	"strings"
	"testing"
)

type reviewRPC struct {
	pb.GatewayClient
	register func(*pb.DeltaReview) (*pb.ReviewRegistrationReceipt, error)
}

func (r reviewRPC) RegisterPublicationReview(_ context.Context, p *pb.DeltaReview, _ ...grpc.CallOption) (*pb.ReviewRegistrationReceipt, error) {
	return r.register(p)
}
func TestReviewRegistrationFreezesParentAndRequiresBoundReceipt(t *testing.T) {
	p := v1.Publication{OperationID: "original", Fence: 1, Policy: "permit(principal,action,resource);", Schema: "{}"}
	digest, err := p.Digest()
	if err != nil {
		t.Fatal(err)
	}
	schema := strings.Repeat("8", 64)
	e := v1.DeltaReview{Review: v1.PublicationReview{Publication: v1.PublicationKey{OperationID: p.OperationID, Digest: digest}, Parent: &v1.AuthorityParent{Revision: 0, Fence: 1, PolicyDigest: strings.Repeat("7", 64), SchemaDigest: &schema}, Artifact: "test evidence"}, Audience: "test-gateway", SourceIdentityDigest: strings.Repeat("2", 64), Disposition: v1.DeltaNoExecutionGain, Delta: "synthetic test report", Signature: strings.Repeat("1", 128)}
	expected, err := e.Review.Digest()
	if err != nil {
		t.Fatal(err)
	}
	called := 0
	c := Client{RPC: reviewRPC{register: func(request *pb.DeltaReview) (*pb.ReviewRegistrationReceipt, error) {
		called++
		*e.Review.Parent.SchemaDigest = strings.Repeat("9", 64)
		if *request.Review.Parent.SchemaDigest == *e.Review.Parent.SchemaDigest {
			t.Fatal("caller changed queued evidence")
		}
		return &pb.ReviewRegistrationReceipt{Publication: &pb.PublicationKey{OperationId: p.OperationID, Digest: digest}, ReviewDigest: expected}, nil
	}}}
	if err := c.RegisterReview(context.Background(), p, e); err != nil {
		t.Fatal(err)
	}
	if called != 1 {
		t.Fatal("registration count", called)
	}
	c.RPC = reviewRPC{register: func(*pb.DeltaReview) (*pb.ReviewRegistrationReceipt, error) {
		return &pb.ReviewRegistrationReceipt{Publication: &pb.PublicationKey{OperationId: "renamed", Digest: digest}, ReviewDigest: expected}, nil
	}}
	if err := c.RegisterReview(context.Background(), p, e); err == nil {
		t.Fatal("unbound registry reply accepted")
	}
}
