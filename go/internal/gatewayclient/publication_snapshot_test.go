// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package gatewayclient

import (
	"context"
	"math"
	"testing"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

// Synchronous boundary mutations require no data race. Each request is recorded
// before mutation, as a transport would serialize it before returning a result.
type publicationSnapshotRPC struct {
	pb.GatewayClient
	original v1.Publication
	caller   *uint64
	mode     uint8
	requests []*pb.PublishRequest
}

func (r *publicationSnapshotRPC) record(request *pb.PublishRequest) {
	r.requests = append(r.requests, proto.Clone(request).(*pb.PublishRequest))
	if r.mode%2 == 0 && r.caller != nil {
		*r.caller = *r.caller + 1
	} else if request.ExpectedRevision != nil {
		*request.ExpectedRevision = *request.ExpectedRevision + 1
	}
}

func (r *publicationSnapshotRPC) StageAuthority(_ context.Context, request *pb.PublishRequest, _ ...grpc.CallOption) (*pb.PublicationKey, error) {
	r.record(request)
	if r.mode == 2 || r.mode == 3 {
		return nil, status.Error(codes.Unavailable, "staging result unknown")
	}
	digest, err := r.original.Digest()
	return &pb.PublicationKey{OperationId: r.original.OperationID, Digest: digest}, err
}

func (r *publicationSnapshotRPC) PublishAuthority(_ context.Context, request *pb.PublishRequest, _ ...grpc.CallOption) (*pb.PublicationReceipt, error) {
	r.record(request)
	if r.mode >= 4 {
		return nil, status.Error(codes.Unavailable, "commit result unknown")
	}
	digest, err := r.original.Digest()
	revision := uint64(0)
	if r.original.ExpectedRevision != nil {
		revision = *r.original.ExpectedRevision + 1
	}
	fence := r.original.Fence
	return &pb.PublicationReceipt{OperationId: r.original.OperationID, Digest: digest, Outcome: pb.PublicationOutcome_COMMITTED, Revision: &revision, Fence: &fence}, err
}

func FuzzPublicationStagesRetainOriginalParent(f *testing.F) {
	for mode := uint8(0); mode < 6; mode++ {
		f.Add(uint64(0), true, mode)
		f.Add(uint64(1)<<53+1, true, mode)
		f.Add(uint64(math.MaxInt64-1), true, mode)
		f.Add(uint64(0), false, mode)
	}
	f.Fuzz(func(t *testing.T, parent uint64, present bool, mode uint8) {
		parent %= math.MaxInt64
		expectedParent := parent
		input := v1.Publication{OperationID: "original", Fence: 1, Policy: "permit(principal,action,resource);", Schema: "{}"}
		expected := input
		if present {
			input.ExpectedRevision = &parent
			expected.ExpectedRevision = &expectedParent
		}
		rpc := &publicationSnapshotRPC{original: expected, caller: input.ExpectedRevision, mode: mode % 6}
		client := &Client{RPC: rpc, Token: "source-token"}
		_, err := client.Publish(context.Background(), input)
		if rpc.mode < 2 && err != nil {
			t.Fatal("publication changed after initial snapshot", err)
		}
		if rpc.mode >= 2 && status.Code(err) != codes.Unavailable {
			t.Fatal("unknown outcome was retried or reinterpreted", err)
		}
		count := 2
		if rpc.mode == 2 || rpc.mode == 3 {
			count = 1
		}
		if len(rpc.requests) != count {
			t.Fatal("publication stage was retried", len(rpc.requests))
		}
		for _, request := range rpc.requests {
			// Construct the oracle directly, independently of Publication's copier.
			want := &pb.PublishRequest{OperationId: expected.OperationID, ExpectedRevision: expected.ExpectedRevision, Fence: expected.Fence, Policy: expected.Policy, Schema: expected.Schema}
			if !proto.Equal(request, want) {
				t.Fatal("stage replaced the original ID, parent or Policy", request)
			}
		}
	})
}
