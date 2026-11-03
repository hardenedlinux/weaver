// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"sync/atomic"
	"testing"
	"time"
)

// Responses are lost only after the real server has completed the actual RPC.
// No synthetic SQL result or Drop-only approximation supplies these outcomes.
type reviewReplyLoss struct {
	pb.GatewayClient
	registration, publication atomic.Bool
	publishCalls              atomic.Int64
}

func (r *reviewReplyLoss) RegisterPublicationReview(ctx context.Context, p *pb.DeltaReview, o ...grpc.CallOption) (*pb.ReviewRegistrationReceipt, error) {
	result, err := r.GatewayClient.RegisterPublicationReview(ctx, p, o...)
	if err == nil && r.registration.Swap(false) {
		return nil, status.Error(codes.Unavailable, "actual registration committed; response discarded")
	}
	return result, err
}
func (r *reviewReplyLoss) PublishAuthority(ctx context.Context, p *pb.PublishRequest, o ...grpc.CallOption) (*pb.PublicationReceipt, error) {
	r.publishCalls.Add(1)
	result, err := r.GatewayClient.PublishAuthority(ctx, p, o...)
	if err == nil && r.publication.Swap(false) {
		return nil, status.Error(codes.Unavailable, "actual publication committed; response discarded")
	}
	return result, err
}
func TestProviderReviewedPublicationLostRepliesAndRestart(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	reviewer := f.admin.RPC.(*fixtureReviewer)
	raw := reviewer.GatewayClient
	client := *f.admin
	client.RPC = raw
	p := pendingChange(f, "independently-reviewed-revocation")
	p.Policy = "forbid(principal,action,resource);"
	if err := client.StagePublication(ctx, p); err != nil {
		t.Fatal(err)
	}
	if _, err := client.FinalizePublication(ctx, p); err == nil {
		t.Fatal("missing signed review published")
	}
	e, err := reviewer.review(client.Context(ctx), p)
	if err != nil || e == nil {
		t.Fatal("external producer", err)
	}
	forged := e.Clone()
	forged.Delta += "substitution"
	if err := client.RegisterReview(ctx, p, forged); err == nil {
		t.Fatal("forged Delta registered")
	}
	loss := &reviewReplyLoss{GatewayClient: raw}
	loss.registration.Store(true)
	client.RPC = loss
	p.Review = e
	if _, err := client.FinalizePublication(ctx, p); status.Code(err) != codes.Unavailable {
		t.Fatal("real registration reply was not lost", err)
	}
	if loss.publishCalls.Load() != 0 {
		t.Fatal("unknown registration led to publication")
	}
	if _, err := client.InspectPublication(ctx, p); status.Code(err) != codes.NotFound {
		t.Fatal("registration activated Policy", err)
	}
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil || f.primary.Load() != 0 {
		t.Fatal("pending proposal allowed sending", err)
	}
	f.stop(t)
	f.start(t)
	raw = f.admin.RPC.(*fixtureReviewer).GatewayClient
	client = *f.admin
	loss = &reviewReplyLoss{GatewayClient: raw}
	loss.publication.Store(true)
	client.RPC = loss
	if _, err := client.FinalizePublication(ctx, p); status.Code(err) != codes.Unavailable {
		t.Fatal("real publication reply was not lost", err)
	}
	receipt, err := client.InspectPublication(ctx, p)
	if err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatal("original outcome", receipt, err)
	}
	f.plan.Revision, f.plan.Fence = 1, 2
	if _, _, err := execute(t, f, pb.Encoding_ARROW_IPC, 2); err == nil || f.primary.Load() != 0 {
		t.Fatal("reviewed revocation failed final Policy", err)
	}
	f.stop(t)
	f.start(t)
	client = *f.admin
	client.RPC = f.admin.RPC.(*fixtureReviewer).GatewayClient
	again, err := client.InspectPublication(ctx, p)
	if err != nil || again.GetDigest() != receipt.GetDigest() || again.GetRevision() != receipt.GetRevision() {
		t.Fatal("restart replaced original outcome", again, err)
	}
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil || f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("restart bypassed reviewed revocation", err)
	}
	if loss.publishCalls.Load() != 1 {
		t.Fatal("automatic publication retry", loss.publishCalls.Load())
	}
}
