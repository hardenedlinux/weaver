package gatewayclient

import (
	"context"
	"errors"
	"math"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var ErrPublicationRejected = errors.New("original publication CAS rejected")

// ObserveOrPublish reads the original durable decision before one initial CAS.
// NotFound does not abort a possibly late command: the identical ID, payload and
// parent still go through Rust's final CAS. No failed Publish is retried here.
func (c *Client) ObserveOrPublish(ctx context.Context, p v1.Publication) (*pb.PublicationReceipt, error) {
	p = snapshotPublication(p)
	receipt, err := c.InspectPublication(ctx, p)
	if err == nil {
		if receipt.Outcome == pb.PublicationOutcome_REJECTED {
			return receipt, ErrPublicationRejected
		}
		return receipt, nil
	}
	if status.Code(err) != codes.NotFound {
		return nil, err
	}
	return c.Publish(ctx, p)
}

func Publication(p v1.Publication) *pb.PublishRequest {
	p = snapshotPublication(p)
	return &pb.PublishRequest{OperationId: p.OperationID, ExpectedRevision: p.ExpectedRevision, Fence: p.Fence, Policy: p.Policy, Schema: p.Schema}
}

// Snapshot before the first RPC and keep that proposal across all stages. The
// caller must keep input stable during this initial copy; this is not concurrent
// memory synchronization. Each outbound request receives its own parent too.
func snapshotPublication(p v1.Publication) v1.Publication {
	if p.ExpectedRevision != nil {
		parent := *p.ExpectedRevision
		p.ExpectedRevision = &parent
	}
	return p
}

// Publish stages the exact proposal then makes one final CAS call. Errors never
// trigger automatic resubmission or CAS rebasing; staging alone cannot activate.
func (c *Client) Publish(ctx context.Context, p v1.Publication) (*pb.PublicationReceipt, error) {
	p = snapshotPublication(p)
	if err := c.StagePublication(ctx, p); err != nil {
		return nil, err
	}
	return c.FinalizePublication(ctx, p)
}

// FinalizePublication makes the one final CAS call. It grants no activation by
// itself; staged control handoffs call this only after staging and registration.
func (c *Client) FinalizePublication(ctx context.Context, p v1.Publication) (*pb.PublicationReceipt, error) {
	p = snapshotPublication(p)
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

// StagePublication makes one source-only call. A lost reply leaves an unknown
// durable barrier; retry uses the original proposal and never invents a new ID.
// Success is not a final decision and does not activate operation ingress.
func (c *Client) StagePublication(ctx context.Context, p v1.Publication) error {
	p = snapshotPublication(p)
	digest, err := p.Digest()
	if err != nil {
		return err
	}
	key, err := c.RPC.StageAuthority(c.Context(ctx), Publication(p))
	if err != nil {
		return err
	}
	if key == nil || key.OperationId != p.OperationID || key.Digest != digest {
		return errors.New("publication staging binding")
	}
	return nil
}

// InspectPublication only observes the original decision. NotFound is not abort.
func (c *Client) InspectPublication(ctx context.Context, p v1.Publication) (*pb.PublicationReceipt, error) {
	p = snapshotPublication(p)
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
