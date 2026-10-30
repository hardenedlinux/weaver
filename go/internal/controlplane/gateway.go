// Package controlplane composes source configuration, routing and the Rust owner.
package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/routing"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"io"
	"unicode/utf8"
)

type Gateway struct {
	pb.UnimplementedGatewayServer
	owner      *gatewayclient.Client
	tasks      map[string]v1.Task
	operations map[[2]string]bool
	view       v1.View
}

// Bootstrap has no execution API calls. Unknown publication outcomes never activate ingress.
// Task registration is persistent and idempotent, not an atomic multi-task transaction.
func Bootstrap(ctx context.Context, source, owner *gatewayclient.Client, bundle config.Bundle) (*Gateway, error) {
	if source == nil || owner == nil {
		return nil, errors.New("source and operation authority roles required")
	}
	data, err := json.Marshal(bundle)
	if err != nil {
		return nil, err
	}
	frozen, err := config.DecodeBundle(data, config.ProfileJSON)
	if err != nil {
		return nil, err
	}
	for _, task := range frozen.Tasks {
		if _, err = source.RPC.RegisterTask(source.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(task)}); err != nil {
			return nil, err
		}
	}
	receipt, err := source.ObserveOrPublish(ctx, frozen.Publication)
	if err != nil {
		return nil, err
	}
	if receipt.GetRevision() != frozen.View().Revision || receipt.GetFence() != frozen.View().Fence {
		return nil, errors.New("source activation observation")
	}
	g := &Gateway{owner: owner, tasks: map[string]v1.Task{}, operations: map[[2]string]bool{}, view: frozen.View()}
	for _, task := range frozen.Tasks {
		g.tasks[task.Family] = task
	}
	for _, plan := range frozen.Plans {
		g.operations[[2]string{plan.Family, plan.Node}] = true
	}
	return g, nil
}

func (g *Gateway) ExecuteProvider(in *pb.ProviderRequest, out pb.Gateway_ExecuteProviderServer) error {
	if in == nil || in.Plan == nil || !utf8.Valid(in.Plan.Body) {
		return status.Error(codes.InvalidArgument, "provider proposal required")
	}
	p := in.Plan
	if !g.operations[[2]string{p.Family, p.Node}] {
		return status.Error(codes.PermissionDenied, "unregistered operation")
	}
	routes := make([]v1.ProviderRoute, 0, len(p.Routes))
	for _, r := range p.Routes {
		if r == nil {
			return status.Error(codes.InvalidArgument, "route required")
		}
		routes = append(routes, v1.ProviderRoute{Target: r.Target, Endpoint: r.Endpoint})
	}
	proposal := v1.ProviderPlan{Family: p.Family, Node: p.Node, Profile: p.Profile, ProfileCommitment: p.ProfileCommitment, Model: p.Model, Body: string(p.Body), Routes: routes, Ceiling: p.Ceiling}
	compiled, err := routing.CompileProvider(g.tasks[p.Family], proposal, g.view)
	if err != nil {
		return status.Error(codes.PermissionDenied, "source contract rejected")
	}
	ctx, cancel := context.WithCancel(out.Context())
	defer cancel()
	upstream, err := g.owner.RPC.ExecuteProvider(g.owner.Context(ctx), &pb.ProviderRequest{Plan: gatewayclient.Plan(compiled), Encoding: in.Encoding, BatchRows: in.BatchRows})
	if err != nil {
		return err
	}
	for {
		frame, err := upstream.Recv()
		if err == io.EOF {
			out.SetTrailer(upstream.Trailer())
			return nil
		}
		if err != nil {
			out.SetTrailer(upstream.Trailer())
			return err
		}
		if err = out.Send(frame); err != nil {
			return err
		}
	}
}

func (g *Gateway) Inspect(ctx context.Context, key *pb.OperationKey) (*pb.ProviderReceipt, error) {
	if key == nil || !g.operations[[2]string{key.Family, key.Node}] {
		return nil, status.Error(codes.PermissionDenied, "unregistered operation")
	}
	return g.owner.RPC.Inspect(g.owner.Context(ctx), key)
}
