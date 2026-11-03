// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package gatewayclient

import (
	"context"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

// StageReviewedPublication opts into the existing mandatory-review staging contract.
// This preparation does not activate Policy, register tasks or execute a provider.
func (c *Client) StageReviewedPublication(ctx context.Context, p v1.Publication) error {
	p = p.Clone()
	digest, err := p.Digest()
	if err != nil {
		return err
	}
	result, err := c.RPC.StageReviewedAuthority(c.Context(ctx), Publication(p))
	if err != nil {
		return err
	}
	if result == nil || result.OperationId != p.OperationID || result.Digest != digest {
		return errors.New("review staging binding")
	}
	return nil
}

// ReviewContext reads the original authority-owned parent/source/issuer references.
func (c *Client) ReviewContext(ctx context.Context, p v1.Publication) (*pb.PublicationReviewContext, error) {
	digest, err := p.Digest()
	if err != nil {
		return nil, err
	}
	result, err := c.RPC.InspectPublicationReview(c.Context(ctx), &pb.PublicationKey{OperationId: p.OperationID, Digest: digest})
	if err != nil {
		return nil, err
	}
	if result == nil || result.Publication == nil || result.Publication.OperationId != p.OperationID || result.Publication.Digest != digest || result.Reviewer == nil || result.Source == nil {
		return nil, errors.New("review context binding")
	}
	return result, nil
}

// ReviewMessage freezes every nullable field. It does not sign or approve evidence.
func ReviewMessage(evidence v1.DeltaReview) (*pb.DeltaReview, error) {
	evidence = evidence.Clone()
	if _, err := evidence.SigningDigest(); err != nil {
		return nil, err
	}
	var parent *pb.AuthorityParent
	if p := evidence.Review.Parent; p != nil {
		parent = &pb.AuthorityParent{Revision: p.Revision, Fence: p.Fence, PolicyDigest: p.PolicyDigest, SchemaDigest: p.SchemaDigest}
	}
	kind := pb.DeltaDisposition_DELTA_DISPOSITION_UNSPECIFIED
	switch evidence.Disposition {
	case v1.DeltaBootstrap:
		kind = pb.DeltaDisposition_BOOTSTRAP
	case v1.DeltaNoExecutionGain:
		kind = pb.DeltaDisposition_NO_EXECUTION_GAIN
	case v1.DeltaExplicitApproval:
		kind = pb.DeltaDisposition_EXPLICIT_APPROVAL
	}
	return &pb.DeltaReview{Review: &pb.PublicationReview{Publication: &pb.PublicationKey{OperationId: evidence.Review.Publication.OperationID, Digest: evidence.Review.Publication.Digest}, Parent: parent, Artifact: evidence.Review.Artifact}, Audience: evidence.Audience, ReviewerEpoch: evidence.ReviewerEpoch, SourceEpoch: evidence.SourceEpoch, SourceIdentityDigest: evidence.SourceIdentityDigest, Disposition: kind, Delta: evidence.Delta, Signature: evidence.Signature}, nil
}

// RegisterReview submits independently issued evidence once and checks its receipt.
// The publisher has no signer, semantic solver, inferred approval or retry loop.
func (c *Client) RegisterReview(ctx context.Context, p v1.Publication, evidence v1.DeltaReview) error {
	evidence = evidence.Clone()
	digest, err := p.Digest()
	if err != nil {
		return err
	}
	if evidence.Review.Publication.OperationID != p.OperationID || evidence.Review.Publication.Digest != digest {
		return errors.New("review publication binding")
	}
	reviewed, err := evidence.Review.Digest()
	if err != nil {
		return err
	}
	request, err := ReviewMessage(evidence)
	if err != nil {
		return err
	}
	result, err := c.RPC.RegisterPublicationReview(c.Context(ctx), request)
	if err != nil {
		return err
	}
	if result == nil || result.Publication == nil || result.Publication.OperationId != p.OperationID || result.Publication.Digest != digest || result.ReviewDigest != reviewed {
		return errors.New("registered review binding")
	}
	return nil
}
