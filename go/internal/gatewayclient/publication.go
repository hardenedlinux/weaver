package gatewayclient

import (
	"context"
	"errors"
	"math"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

var ErrPublicationRejected = errors.New("original publication CAS rejected")

func Publication(p v1.Publication) *pb.PublishRequest {
	return &pb.PublishRequest{OperationId: p.OperationID, ExpectedRevision: p.ExpectedRevision, Fence: p.Fence, Policy: p.Policy, Schema: p.Schema}
}

// Publish makes one RPC. Errors never trigger automatic resubmission or CAS rebasing.
func (c *Client) Publish(ctx context.Context, p v1.Publication) (*pb.PublicationReceipt, error) {
	digest, err := p.Digest()
	if err != nil {
		return nil, err
	}
	receipt, err := c.RPC.PublishAuthority(c.Context(ctx), Publication(p))
	if err != nil {
		return nil, err
	}
	if err = validatePublication(p, digest, receipt); err != nil {
		return nil, err
	}
	if receipt.Outcome == pb.PublicationOutcome_REJECTED {
		return receipt, ErrPublicationRejected
	}
	return receipt, nil
}

// InspectPublication only observes the original decision. NotFound is not abort.
func (c *Client) InspectPublication(ctx context.Context, p v1.Publication) (*pb.PublicationReceipt, error) {
	digest, err := p.Digest()
	if err != nil {
		return nil, err
	}
	receipt, err := c.RPC.InspectPublication(c.Context(ctx), &pb.PublicationKey{OperationId: p.OperationID, Digest: digest})
	if err != nil {
		return nil, err
	}
	if err = validatePublication(p, digest, receipt); err != nil {
		return nil, err
	}
	return receipt, nil
}

func validatePublication(p v1.Publication, digest string, r *pb.PublicationReceipt) error {
	if r == nil || r.OperationId != p.OperationID || r.Digest != digest || (r.Revision == nil) != (r.Fence == nil) || r.GetRevision() > math.MaxInt64 || r.GetFence() > math.MaxInt64 {
		return errors.New("publication receipt binding")
	}
	switch r.Outcome {
	case pb.PublicationOutcome_COMMITTED:
		revision := uint64(0)
		if p.ExpectedRevision != nil {
			revision = *p.ExpectedRevision + 1
		}
		if r.Revision == nil || r.GetRevision() != revision || r.GetFence() != p.Fence {
			return errors.New("publication committed outcome")
		}
	case pb.PublicationOutcome_REJECTED:
		if r.Revision == nil && p.ExpectedRevision == nil {
			return errors.New("publication impossible absent rejection")
		}
	default:
		return errors.New("publication outcome missing")
	}
	return nil
}
