// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"context"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
)

// Pure wire projection. Selection, topology and canonical checks belong to Scheme/Rust.
func sourceCompositionRequest(bundle config.Bundle, catalog bool, version string) *pb.SourceCompositionRequest {
	g := bundle.Governance
	selection := &pb.GovernanceSelection{Schema: g.Schema, Family: g.Family, OpenNodes: g.OpenNodes}
	for _, edge := range g.WorkflowEdges {
		selection.WorkflowEdges = append(selection.WorkflowEdges, &pb.WorkflowEdge{Dependent: edge[0], Dependency: edge[1]})
	}
	for _, row := range g.WorkflowSelectors {
		selection.WorkflowSelectors = append(selection.WorkflowSelectors, &pb.WorkflowSelector{Selector: row[0], Left: row[1], Right: row[2]})
	}
	source := &pb.SourceArtifact{Governance: selection, Publication: gatewayclient.Publication(bundle.Publication)}
	for _, task := range bundle.Tasks {
		source.Tasks = append(source.Tasks, gatewayclient.Task(task))
	}
	for _, plan := range bundle.Plans {
		source.Plans = append(source.Plans, gatewayclient.Plan(plan))
	}
	request := &pb.SourceCompositionRequest{Source: source, UseCatalog: catalog, ExpectedCatalogVersion: version}
	for _, row := range bundle.Routing {
		selection := &pb.RoutingSelection{Node: row.Node, AllowedModules: row.AllowedModules, Required: row.Required,
			MaxLatencyMs: row.MaxLatencyMillis, MaxProcurementCost: row.MaxProcurementCost, UserTokenRates: row.UserTokenRates[:]}
		for _, candidate := range row.Candidates {
			selection.Candidates = append(selection.Candidates, &pb.RoutingCandidate{Module: candidate.Module,
				Capabilities: candidate.Capabilities, LatencyMs: candidate.LatencyMillis,
				ProcurementRates: candidate.ProcurementRates[:], TokenBounds: candidate.TokenBounds[:], Plan: gatewayclient.Plan(candidate.Plan)})
		}
		request.Routing = append(request.Routing, selection)
	}
	return request
}
func composeSourceBundle(ctx context.Context, source *gatewayclient.Client, bundle config.Bundle, catalog bool, version string) (config.Bundle, error) {
	reply, err := source.RPC.ComposeSource(source.Context(ctx), sourceCompositionRequest(bundle, catalog, version))
	if err != nil {
		return config.Bundle{}, err
	}
	if reply == nil || reply.CatalogVersion != version {
		return config.Bundle{}, errors.New("composition version changed")
	}
	selected, err := compiledBundle(reply.Artifact)
	if err != nil {
		return config.Bundle{}, err
	}
	// Independently issued review custody is transport data, never recomputed by
	// the semantic planner. Rust still verifies its exact publication binding.
	selected.Publication.Review = bundle.Publication.Clone().Review
	return selected, nil
}
