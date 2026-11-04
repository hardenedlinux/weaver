// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// This test-only independent producer authenticates boundary fixtures. It does
// not run SPEC Delta analysis and must never count as semantic proof evidence.
// The production control process receives only its signed result, never this key.
type fixtureReviewer struct {
	pb.GatewayClient
	key ed25519.PrivateKey
}

func (r *fixtureReviewer) review(ctx context.Context, p v1.Publication) (*v1.DeltaReview, error) {
	digest, err := p.Digest()
	if err != nil {
		return nil, err
	}
	key, err := r.StageReviewedAuthority(ctx, gatewayclient.Publication(p))
	if err != nil {
		return nil, err
	}
	if key.OperationId != p.OperationID || key.Digest != digest {
		return nil, errors.New("test review original binding")
	}
	c, err := r.InspectPublicationReview(ctx, key)
	if err != nil {
		return nil, err
	}
	if c.Reviewer == nil || c.Source == nil {
		return nil, errors.New("test review context missing")
	}
	// A stale original CAS may only reject. Do not invent a new parent/rebase.
	if (p.ExpectedRevision == nil) != (c.Parent == nil) || (c.Parent != nil && c.Parent.Revision != *p.ExpectedRevision) {
		return nil, nil
	}
	var parent *v1.AuthorityParent
	if c.Parent != nil {
		parent = &v1.AuthorityParent{Revision: c.Parent.Revision, Fence: c.Parent.Fence, PolicyDigest: c.Parent.PolicyDigest, SchemaDigest: c.Parent.SchemaDigest}
	}
	kind := v1.DeltaBootstrap
	if parent != nil {
		kind = v1.DeltaExplicitApproval
	}
	e := v1.DeltaReview{Review: v1.PublicationReview{Publication: v1.PublicationKey{OperationID: p.OperationID, Digest: digest}, Parent: parent, Artifact: "independent synthetic producer fixture"}, Audience: c.Reviewer.Audience, ReviewerEpoch: c.Reviewer.Epoch, SourceEpoch: c.Source.Epoch, SourceIdentityDigest: c.Source.IdentityDigest, Disposition: kind, Delta: "boundary test only; no SPEC semantic proof claim"}
	signing, err := e.SigningDigest()
	if err != nil {
		return nil, err
	}
	bytes, err := hex.DecodeString(signing)
	if err != nil {
		return nil, err
	}
	e.Signature = hex.EncodeToString(ed25519.Sign(r.key, bytes))
	return &e, nil
}
func (r *fixtureReviewer) PublishAuthority(ctx context.Context, in *pb.PublishRequest, options ...grpc.CallOption) (*pb.PublicationReceipt, error) {
	p := v1.Publication{OperationID: in.OperationId, ExpectedRevision: in.ExpectedRevision, Fence: in.Fence, Policy: in.Policy, Schema: in.Schema}
	digest, err := p.Digest()
	if err != nil {
		return nil, err
	}
	_, err = r.InspectPublication(ctx, &pb.PublicationKey{OperationId: p.OperationID, Digest: digest})
	if err != nil && status.Code(err) != codes.NotFound {
		return nil, err
	}
	if status.Code(err) == codes.NotFound {
		e, err := r.review(ctx, p)
		if err != nil {
			return nil, err
		}
		if e != nil {
			wire, err := gatewayclient.ReviewMessage(*e)
			if err != nil {
				return nil, err
			}
			if _, err = r.RegisterPublicationReview(ctx, wire); err != nil {
				// The captured parent can have advanced after staging. The
				// actual CAS may record only the original stale rejection;
				// mandatory native review still blocks any possible commit.
				if status.Code(err) == codes.FailedPrecondition {
					return r.GatewayClient.PublishAuthority(ctx, in, options...)
				}
				return nil, err
			}
		}
	}
	return r.GatewayClient.PublishAuthority(ctx, in, options...)
}
