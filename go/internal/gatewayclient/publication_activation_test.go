package gatewayclient

import (
	"context"
	"errors"
	"testing"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type activationRPC struct {
	pb.GatewayClient
	inspect       func(*pb.PublicationKey) (*pb.PublicationReceipt, error)
	publish       func(*pb.PublishRequest) (*pb.PublicationReceipt, error)
	reads, writes int
}

func (r *activationRPC) InspectPublication(_ context.Context, key *pb.PublicationKey, _ ...grpc.CallOption) (*pb.PublicationReceipt, error) {
	r.reads++
	return r.inspect(key)
}
func (r *activationRPC) PublishAuthority(_ context.Context, p *pb.PublishRequest, _ ...grpc.CallOption) (*pb.PublicationReceipt, error) {
	r.writes++
	return r.publish(p)
}

func TestActivationReadsOriginalDecisionBeforeSubmission(t *testing.T) {
	parent, fence, next := uint64(4), uint64(8), uint64(5)
	proposal := v1.Publication{OperationID: "source-activation", ExpectedRevision: &parent, Fence: fence, Policy: "permit(principal,action,resource);", Schema: "{}"}
	digest, err := proposal.Digest()
	if err != nil {
		t.Fatal(err)
	}
	good := func() *pb.PublicationReceipt {
		return &pb.PublicationReceipt{OperationId: proposal.OperationID, Digest: digest, Outcome: pb.PublicationOutcome_COMMITTED, Revision: &next, Fence: &fence}
	}
	for _, outcome := range []pb.PublicationOutcome{pb.PublicationOutcome_COMMITTED, pb.PublicationOutcome_REJECTED} {
		t.Run(outcome.String(), func(t *testing.T) {
			rpc := &activationRPC{inspect: func(key *pb.PublicationKey) (*pb.PublicationReceipt, error) {
				if key.OperationId != proposal.OperationID || key.Digest != digest {
					t.Fatal("original query identity changed")
				}
				r := good()
				r.Outcome = outcome
				return r, nil
			}}
			r, err := (&Client{RPC: rpc}).ObserveOrPublish(t.Context(), proposal)
			if rpc.reads != 1 || rpc.writes != 0 || r == nil {
				t.Fatal("existing decision caused a source write")
			}
			if outcome == pb.PublicationOutcome_REJECTED && !errors.Is(err, ErrPublicationRejected) {
				t.Fatal("rejected original decision activated", err)
			}
			if outcome == pb.PublicationOutcome_COMMITTED && err != nil {
				t.Fatal(err)
			}
		})
	}
	t.Run("absent outcome and lost submission reply", func(t *testing.T) {
		rpc := &activationRPC{inspect: func(*pb.PublicationKey) (*pb.PublicationReceipt, error) {
			return nil, status.Error(codes.NotFound, "not observed")
		}, publish: func(p *pb.PublishRequest) (*pb.PublicationReceipt, error) {
			if p.OperationId != proposal.OperationID || p.GetExpectedRevision() != parent || p.Fence != fence {
				t.Fatal("submission rebased original command")
			}
			return nil, status.Error(codes.Unavailable, "unknown commit")
		}}
		if _, err := (&Client{RPC: rpc}).ObserveOrPublish(t.Context(), proposal); status.Code(err) != codes.Unavailable {
			t.Fatal(err)
		}
		if rpc.reads != 1 || rpc.writes != 1 {
			t.Fatal("ambiguous publication was retried")
		}
	})
	for _, code := range []codes.Code{codes.Unavailable, codes.PermissionDenied, codes.ResourceExhausted, codes.Unimplemented} {
		t.Run(code.String(), func(t *testing.T) {
			rpc := &activationRPC{inspect: func(*pb.PublicationKey) (*pb.PublicationReceipt, error) {
				return nil, status.Error(code, "inspection failed")
			}}
			if _, err := (&Client{RPC: rpc}).ObserveOrPublish(t.Context(), proposal); status.Code(err) != code || rpc.writes != 0 {
				t.Fatal("inspection failure caused publication", err)
			}
		})
	}
	t.Run("mismatched observation", func(t *testing.T) {
		rpc := &activationRPC{inspect: func(*pb.PublicationKey) (*pb.PublicationReceipt, error) {
			r := good()
			r.Digest = "substituted"
			return r, nil
		}}
		if _, err := (&Client{RPC: rpc}).ObserveOrPublish(t.Context(), proposal); err == nil || rpc.writes != 0 {
			t.Fatal("malformed observation activated or published")
		}
	})
	t.Run("frozen parent across inspection", func(t *testing.T) {
		original := parent
		rpc := &activationRPC{inspect: func(*pb.PublicationKey) (*pb.PublicationReceipt, error) {
			parent++
			return nil, status.Error(codes.NotFound, "not observed")
		}, publish: func(p *pb.PublishRequest) (*pb.PublicationReceipt, error) {
			if p.GetExpectedRevision() != original {
				t.Fatal("caller mutation replaced frozen parent")
			}
			return good(), nil
		}}
		defer func() { parent = original }()
		if _, err := (&Client{RPC: rpc}).ObserveOrPublish(t.Context(), proposal); err != nil || rpc.writes != 1 {
			t.Fatal(err)
		}
	})
}
