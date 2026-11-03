// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package gatewayclient

import (
	"context"
	"io"
	"testing"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
)

func FuzzTaskRequestOwnsMutableFields(f *testing.F) {
	for field := uint8(0); field < 8; field++ {
		f.Add(field, false)
		f.Add(field, true)
	}
	f.Fuzz(func(t *testing.T, field uint8, reverse bool) {
		task := v1.Task{Nodes: []string{"infer"}, Targets: []string{"primary"}, Models: []string{"model"},
			Endpoints: map[string]string{"primary": "https://provider.invalid"}, BodyDigests: map[string]string{"infer": "body"},
			StreamContracts: map[string]string{"infer": "stream"}, NodeCostBounds: map[string]uint64{"infer": 4},
			ProviderProfile: &v1.ProviderProfile{MaxMessages: 4}}
		request := Task(task)
		before := proto.Clone(request).(*pb.Task)
		if reverse {
			switch field % 8 {
			case 0:
				request.Nodes[0] = "changed"
			case 1:
				request.Targets[0] = "changed"
			case 2:
				request.Models[0] = "changed"
			case 3:
				request.Endpoints["primary"] = "changed"
			case 4:
				request.BodyDigests["infer"] = "changed"
			case 5:
				request.StreamContracts["infer"] = "changed"
			case 6:
				request.NodeCostBounds["infer"] = 99
			case 7:
				request.ProviderProfile.MaxMessages = 99
			}
			if !proto.Equal(Task(task), before) {
				t.Fatal("request mutation changed the retained original task")
			}
		} else {
			switch field % 8 {
			case 0:
				task.Nodes[0] = "changed"
			case 1:
				task.Targets[0] = "changed"
			case 2:
				task.Models[0] = "changed"
			case 3:
				task.Endpoints["primary"] = "changed"
			case 4:
				task.BodyDigests["infer"] = "changed"
			case 5:
				task.StreamContracts["infer"] = "changed"
			case 6:
				task.NodeCostBounds["infer"] = 99
			case 7:
				task.ProviderProfile.MaxMessages = 99
			}
			if !proto.Equal(request, before) {
				t.Fatal("request retained caller-owned task storage")
			}
		}
	})
}

type ownedProviderStream struct {
	grpc.ClientStream
	frames []*pb.ProviderFrame
}

func (s *ownedProviderStream) Recv() (*pb.ProviderFrame, error) {
	if len(s.frames) == 0 {
		return nil, io.EOF
	}
	frame := s.frames[0]
	s.frames = s.frames[1:]
	return frame, nil
}

type ownedProviderRPC struct {
	pb.GatewayClient
	open              func(*pb.ProviderRequest)
	stream            ownedProviderStream
	receipt           *pb.ProviderReceipt
	executions, reads int
}

func (r *ownedProviderRPC) ExecuteProvider(_ context.Context, request *pb.ProviderRequest, _ ...grpc.CallOption) (pb.Gateway_ExecuteProviderClient, error) {
	r.executions++
	r.open(request)
	return &r.stream, nil
}

func (r *ownedProviderRPC) Inspect(context.Context, *pb.OperationKey, ...grpc.CallOption) (*pb.ProviderReceipt, error) {
	r.reads++
	return r.receipt, nil
}

func FuzzProviderExecutionOwnsRouteObservation(f *testing.F) {
	for mode := uint8(0); mode < 3; mode++ {
		f.Add(mode, false)
		f.Add(mode, true)
	}
	f.Fuzz(func(t *testing.T, mode uint8, forged bool) {
		plan := v1.ProviderPlan{Family: "f", Node: "infer", Model: "model", Ceiling: 4,
			Routes: []v1.ProviderRoute{{Target: "primary", Endpoint: "https://provider.invalid"}}}
		digest, err := plan.Digest()
		if err != nil {
			t.Fatal(err)
		}
		rpc := &ownedProviderRPC{receipt: &pb.ProviderReceipt{Family: plan.Family, Node: plan.Node, Digest: digest,
			State: "complete", Target: "primary", Reserved: 4, Held: 4, Events: 3}}
		for index, kind := range []string{"delta", "finish", "done"} {
			target := "primary"
			if forged && index > 0 {
				target = "changed"
			}
			rpc.stream.frames = append(rpc.stream.frames, &pb.ProviderFrame{Model: plan.Model, Target: target,
				Payload: &pb.ProviderFrame_Event{Event: &pb.Event{Sequence: uint64(index), Kind: kind}}})
		}
		rpc.open = func(request *pb.ProviderRequest) {
			if request.Plan.Routes[0].Target != "primary" {
				t.Fatal("request changed before RPC submission")
			}
			switch mode % 3 {
			case 0:
				plan.Routes[0].Target = "changed"
			case 1:
				request.Plan.Routes[0].Target = "changed"
			}
		}
		_, err = (&Client{RPC: rpc, Token: "operation-token"}).Execute(t.Context(), plan, pb.Encoding_PROTOBUF, 1, func(event *pb.Event) error {
			if mode%3 == 2 && event.Sequence == 0 {
				plan.Routes[0].Target = "changed"
			}
			return nil
		})
		if (err != nil) != forged || rpc.executions != 1 || (!forged && rpc.reads != 1) {
			t.Fatal("route observation followed mutable storage, switched target or retried", err)
		}
	})
}
