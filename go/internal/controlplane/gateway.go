// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Package controlplane composes source configuration, routing and the Rust owner.
package controlplane

import (
	"context"
	"errors"
	"io"
	"slices"
	"sync"
	"sync/atomic"
	"unicode/utf8"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/telemetry"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type Gateway struct {
	pb.UnimplementedGatewayServer
	metrics        telemetry.Metrics
	owner          *gatewayclient.Client
	operations     map[[2]string]v1.ProviderPlan
	source         *gatewayclient.Client
	deferred       *config.Bundle
	catalog        atomic.Pointer[catalogProjection]
	catalogBuildMu sync.Mutex
	publication    *pb.PublicationKey
	oauthRelay     bool
}

// Bootstrap has no execution API calls. Unknown publication outcomes never activate ingress.
// Task registration is persistent and idempotent, not an atomic multi-task transaction.
func Bootstrap(ctx context.Context, source, owner *gatewayclient.Client, bundle config.Bundle) (*Gateway, error) {
	if owner == nil {
		return nil, errors.New("operation authority role required")
	}
	return bootstrap(ctx, source, owner, bundle, nil)
}

type bootstrapTrace func(string)

func (trace bootstrapTrace) phase(name string) {
	if trace != nil {
		trace(name)
	}
}

func bootstrap(ctx context.Context, source, owner *gatewayclient.Client, bundle config.Bundle, trace bootstrapTrace) (*Gateway, error) {
	if source == nil {
		return nil, errors.New("source and operation authority roles required")
	}
	frozen, err := config.CloneConfiguration(bundle)
	if err != nil {
		return nil, err
	}
	selected, err := composeSourceBundle(ctx, source, frozen, false, "")
	if err != nil {
		return nil, err
	}
	if !frozen.SelectOnRequest {
		frozen = selected
	} else if len(frozen.Tasks) != 1 || len(frozen.Routing) != 1 || len(frozen.Tasks[0].Nodes) != 1 {
		return nil, errors.New("request routing requires one original task and node")
	}
	return bootstrapFrozen(ctx, source, owner, frozen, trace)
}

// Both callers own a fully validated independent image. Keep this private:
// it removes repeated local projection, never a source or final-use CAS.
func bootstrapFrozen(ctx context.Context, source, owner *gatewayclient.Client, frozen config.Bundle, trace bootstrapTrace) (*Gateway, error) {
	trace.phase("publication-inspect-start")
	receipt, err := source.InspectPublication(ctx, frozen.Publication)
	if err == nil && receipt.GetOutcome() == pb.PublicationOutcome_REJECTED {
		return nil, gatewayclient.ErrPublicationRejected
	}
	if err != nil {
		if status.Code(err) != codes.NotFound {
			return nil, err
		}
		trace.phase("publication-stage-start")
		if err = source.StagePublication(ctx, frozen.Publication); err != nil {
			return nil, err
		}
		receipt = nil
	}
	digest, err := frozen.Publication.Digest()
	if err != nil {
		return nil, err
	}
	trace.phase("task-registration-start")
	_, err = source.RPC.RegisterPublishedTask(source.Context(ctx), &pb.RegisterPublishedTaskRequest{Publication: &pb.PublicationKey{OperationId: frozen.Publication.OperationID, Digest: digest}, SourceScope: sourceCompositionRequest(frozen, false, "")})
	if err != nil {
		return nil, err
	}
	if receipt == nil {
		trace.phase("publication-finalize-start")
		receipt, err = source.FinalizePublication(ctx, frozen.Publication)
		if err != nil {
			return nil, err
		}
	}
	if receipt.GetRevision() != frozen.View().Revision || receipt.GetFence() != frozen.View().Fence {
		return nil, errors.New("source activation observation")
	}
	trace.phase("publication-confirmed")
	g := &Gateway{owner: owner, operations: make(map[[2]string]v1.ProviderPlan, len(frozen.Plans))}
	view := frozen.View()
	for _, plan := range frozen.Plans {
		plan.Revision, plan.Fence = view.Revision, view.Fence
		g.operations[[2]string{plan.Family, plan.Node}] = plan
	}
	if frozen.SelectOnRequest {
		g.source = source
		g.deferred = &frozen
		g.publication = &pb.PublicationKey{OperationId: frozen.Publication.OperationID, Digest: digest}
		g.operations[[2]string{frozen.Tasks[0].Family, frozen.Routing[0].Node}] = v1.ProviderPlan{}
	}
	return g, nil
}

func (g *Gateway) ExecuteProvider(in *pb.ProviderRequest, out pb.Gateway_ExecuteProviderServer) (result error) {
	g.metrics.Record(telemetry.ProviderAdmitted)
	defer func() {
		if result == nil {
			g.metrics.Record(telemetry.ProviderCompleted)
		} else {
			g.metrics.Record(telemetry.ProviderFailed)
		}
	}()
	if in == nil || in.Plan == nil || !utf8.Valid(in.Plan.Body) {
		return status.Error(codes.InvalidArgument, "provider proposal required")
	}
	p := in.Plan
	if _, registered := g.operations[[2]string{p.Family, p.Node}]; !registered {
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
	forward, err := g.providerContext(out.Context())
	if err != nil {
		return err
	}
	compiled, catalog, err := g.compileProvider(out.Context(), proposal)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(forward)
	defer cancel()
	upstream, err := g.owner.RPC.ExecuteProvider(g.owner.Context(ctx), &pb.ProviderRequest{Plan: gatewayclient.Plan(compiled), CatalogVersion: catalog, Encoding: in.Encoding, BatchRows: in.BatchRows})
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
		g.metrics.Record(telemetry.ResponseFramesQueued)
	}
}

// The existing authenticated server interceptor protects this bounded local read.
// No source publication, ledger query, provider call or remote export is involved.
func (g *Gateway) InspectTelemetry(context.Context, *pb.Empty) (*pb.TelemetrySnapshot, error) {
	g.metrics.Record(telemetry.SnapshotReads)
	return g.metrics.Snapshot(), nil
}

func (g *Gateway) Inspect(ctx context.Context, key *pb.OperationKey) (*pb.ProviderReceipt, error) {
	if _, registered := g.operations[[2]string{key.GetFamily(), key.GetNode()}]; !registered {
		return nil, status.Error(codes.PermissionDenied, "unregistered operation")
	}
	forward, err := g.providerContext(ctx)
	if err != nil {
		return nil, err
	}
	return g.owner.RPC.Inspect(g.owner.Context(forward), key)
}

func (g *Gateway) compileProvider(ctx context.Context, proposal v1.ProviderPlan) (v1.ProviderPlan, string, error) {
	if g.deferred == nil {
		original, registered := g.operations[[2]string{proposal.Family, proposal.Node}]
		// Bootstrap validated and took ownership of the exact original. The
		// Rust owner still checks current authority on the submitted plan.
		if !registered || proposal.Profile != original.Profile || proposal.ProfileCommitment != original.ProfileCommitment ||
			proposal.Model != original.Model || proposal.Ceiling != original.Ceiling ||
			!slices.Equal(proposal.Routes, original.Routes) || proposal.Body != original.Body {
			return v1.ProviderPlan{}, "", status.Error(codes.PermissionDenied, "source contract rejected")
		}
		return original, "", nil
	}
	if proposal.Body != "" || proposal.Model != "" || proposal.Profile != "" ||
		proposal.ProfileCommitment != "" || len(proposal.Routes) != 0 || proposal.Ceiling != 0 {
		return v1.ProviderPlan{}, "", status.Error(codes.InvalidArgument, "request routing accepts only the original operation key")
	}
	selected, catalog, err := g.materializeProvider(ctx)
	if err != nil {
		return v1.ProviderPlan{}, "", status.Error(codes.FailedPrecondition, "source routing rejected")
	}
	_, err = g.source.RPC.RegisterPublishedTask(g.source.Context(ctx), selected.registration)
	if err != nil {
		return v1.ProviderPlan{}, "", err
	}
	return selected.bundle.Plans[0], catalog, nil
}
