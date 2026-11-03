// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package controlplane

import (
	"context"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/protobuf/proto"
	"unicode/utf8"
)

// BootstrapProducer joins native registered compilation to the existing exact
// source reconciliation/publication and routing path. Compilation never sends.
func BootstrapProducer(ctx context.Context, source, owner *gatewayclient.Client, producer string) (*Gateway, error) {
	if source == nil || owner == nil {
		return nil, errors.New("source and operation authority roles required")
	}
	reply, err := source.CompileSource(ctx, producer)
	if err != nil {
		return nil, err
	}
	bundle, err := compiledBundle(reply.Artifact)
	if err != nil {
		return nil, err
	}
	return bootstrapFrozen(ctx, source, owner, bundle)
}

// Decode concrete protobuf fields directly. No interop JSON/YAML roundtrip and
// no retained protobuf maps/slices can reinterpret the admitted configuration.
func compiledBundle(input *pb.SourceArtifact) (config.Bundle, error) {
	var zero config.Bundle
	if input == nil || input.Governance == nil || input.Publication == nil || len(input.Tasks) != 1 || len(input.Plans) == 0 || len(input.Plans) > 64 {
		return zero, errors.New("compiled source shape")
	}
	g := input.Governance
	p := input.Publication
	if unknownFields(input) || unknownFields(g) || unknownFields(p) {
		return zero, errors.New("unsupported compiled source field")
	}
	bundle := config.Bundle{Governance: config.Governance{Schema: g.Schema, Family: g.Family, OpenNodes: g.OpenNodes},
		Publication: v1.Publication{OperationID: p.OperationId, ExpectedRevision: cloneRevision(p.ExpectedRevision), Fence: p.Fence, Policy: p.Policy, Schema: p.Schema}}
	for _, t := range input.Tasks {
		if t == nil || unknownFields(t) {
			return zero, errors.New("compiled task missing")
		}
		task := v1.Task{Family: t.Family, Principal: t.Principal, Profile: t.Profile, Nodes: t.Nodes, Targets: t.Targets,
			Models: t.Models, Endpoints: t.Endpoints, BodyDigests: t.BodyDigests,
			NodeCostBounds: t.NodeCostBounds, StreamContracts: t.StreamContracts, Budget: t.Budget}
		if profile := t.ProviderProfile; profile != nil {
			if unknownFields(profile) {
				return zero, errors.New("unsupported compiled profile field")
			}
			task.ProviderProfile = &v1.ProviderProfile{ID: profile.Id, Protocol: profile.Protocol, MaxOutputTokens: profile.MaxOutputTokens,
				MaxMessages: profile.MaxMessages, MaxBodyBytes: profile.MaxBodyBytes}
		}
		bundle.Tasks = append(bundle.Tasks, task)
	}
	for _, p := range input.Plans {
		if p == nil || !utf8.Valid(p.Body) || len(p.Routes) > 8 || unknownFields(p) {
			return zero, errors.New("compiled plan shape")
		}
		plan := v1.ProviderPlan{Family: p.Family, Node: p.Node, Profile: p.Profile, ProfileCommitment: p.ProfileCommitment, Model: p.Model,
			Body: string(p.Body), Ceiling: p.Ceiling, Revision: p.Revision, Fence: p.Fence}
		for _, r := range p.Routes {
			if r == nil || unknownFields(r) {
				return zero, errors.New("compiled route missing")
			}
			plan.Routes = append(plan.Routes, v1.ProviderRoute{Target: r.Target, Endpoint: r.Endpoint})
		}
		bundle.Plans = append(bundle.Plans, plan)
	}
	return config.FreezeBundle(bundle)
}
func unknownFields(message proto.Message) bool { return len(message.ProtoReflect().GetUnknown()) != 0 }
func cloneRevision(value *uint64) *uint64 {
	if value == nil {
		return nil
	}
	copied := *value
	return &copied
}
