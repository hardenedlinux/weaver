// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"bytes"
	"context"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
)

// A projection owns its input and selected bundle. It carries no authority.
type catalogProjection struct {
	version      string
	record       []byte
	bundle       config.Bundle
	registration *pb.RegisterPublishedTaskRequest
}

func (g *Gateway) materializeProvider(ctx context.Context) (*catalogProjection, string, error) {
	snapshot, err := g.source.RPC.InspectProviderCatalog(g.source.Context(ctx), &pb.Empty{})
	if err != nil {
		return nil, "", err
	}
	selected, err := g.composeCatalog(ctx, snapshot)
	return selected, snapshot.Version, err
}

// Cache only immutable composition for the freshly observed exact catalog version.
func (g *Gateway) composeCatalog(ctx context.Context, snapshot *pb.ProviderCatalogSnapshot) (*catalogProjection, error) {
	if current := g.cachedCatalog(snapshot); current != nil {
		return current, nil
	}
	g.catalogBuildMu.Lock()
	defer g.catalogBuildMu.Unlock()
	if current := g.cachedCatalog(snapshot); current != nil {
		return current, nil
	}
	selected, err := composeSourceBundle(ctx, g.source, *g.deferred, true, snapshot.Version)
	if err != nil {
		return nil, err
	}
	projection := &catalogProjection{version: snapshot.Version, record: bytes.Clone(snapshot.Record),
		bundle: selected, registration: g.catalogRegistration(selected)}
	g.catalog.Store(projection)
	return projection, nil
}

func (g *Gateway) catalogRegistration(selected config.Bundle) *pb.RegisterPublishedTaskRequest {
	// This request owns the wire projection. Concurrent RPCs marshal it read-only.
	return &pb.RegisterPublishedTaskRequest{
		Task: gatewayclient.Task(selected.Tasks[0]), Publication: g.publication,
	}
}

func (g *Gateway) cachedCatalog(snapshot *pb.ProviderCatalogSnapshot) *catalogProjection {
	current := g.catalog.Load()
	if current != nil && current.version == snapshot.Version && bytes.Equal(current.record, snapshot.Record) {
		return current
	}
	return nil
}
