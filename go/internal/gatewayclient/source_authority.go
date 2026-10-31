package gatewayclient

import (
	"context"
	"encoding/hex"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"math"
	"strings"
)

var ErrSourceRotationRejected = errors.New("original source rotation rejected")

func validSourceView(view *pb.SourceAuthorityView) bool {
	if view == nil || view.Epoch > math.MaxInt64 {
		return false
	}
	digest, err := hex.DecodeString(view.IdentityDigest)
	return err == nil && len(digest) == 32 && view.IdentityDigest == strings.ToLower(view.IdentityDigest) && view.IdentityDigest != strings.Repeat("0", 64)
}

// SourceAuthority observes current persistent binding. It never grants a later CAS.
func (c *Client) SourceAuthority(ctx context.Context) (*pb.SourceAuthorityView, error) {
	view, err := c.RPC.InspectSourceAuthority(c.Context(ctx), &pb.Empty{})
	if err != nil {
		return nil, err
	}
	if !validSourceView(view) {
		return nil, errors.New("source authority observation")
	}
	return view, nil
}

// RotateSource performs one exact handoff. A failed response is unknown; retry
// only the original request. No automatic retry, rebase or configuration rewrite.
func (c *Client) RotateSource(ctx context.Context, change v1.SourceRotation) (*pb.SourceRotationReceipt, error) {
	digest, err := change.Digest()
	if err != nil {
		return nil, err
	}
	receipt, err := c.RPC.RotateSourceAuthority(c.Context(ctx), &pb.SourceRotationRequest{OperationId: change.OperationID, ExpectedEpoch: change.ExpectedEpoch, NextCertificate: change.NextCertificate, NextCredentialSha256: change.NextCredentialSHA256})
	if err != nil {
		return nil, err
	}
	if receipt == nil || receipt.OperationId != change.OperationID || receipt.Digest != digest || !validSourceView(receipt.Authority) {
		return nil, errors.New("source rotation receipt binding")
	}
	switch receipt.Outcome {
	case pb.SourceRotationOutcome_SOURCE_ROTATED:
		identity, e := change.Identity()
		if e != nil {
			return nil, e
		}
		bound, e := identity.Digest()
		if e != nil {
			return nil, e
		}
		if receipt.Authority.Epoch != change.ExpectedEpoch+1 || receipt.Authority.IdentityDigest != bound {
			return nil, errors.New("source rotation committed binding")
		}
	case pb.SourceRotationOutcome_SOURCE_ROTATION_REJECTED:
		return receipt, ErrSourceRotationRejected
	default:
		return nil, errors.New("source rotation outcome")
	}
	return receipt, nil
}
