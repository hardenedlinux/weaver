// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/routing"
)

type catalogEntry struct {
	Module       string    `json:"module"`
	Capabilities []string  `json:"capabilities"`
	Latency      uint64    `json:"latency_millis"`
	UserRates    [4]uint64 `json:"user_rates"`
	Quote        struct {
		Tenant           string    `json:"tenant"`
		ProcurementRates [4]uint64 `json:"procurement_rates"`
		TokenBounds      [4]uint64 `json:"token_bounds"`
	} `json:"quote"`
}

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
	selected, err := g.projectCatalog(snapshot)
	return selected, snapshot.Version, err
}

func (g *Gateway) projectCatalog(snapshot *pb.ProviderCatalogSnapshot) (*catalogProjection, error) {
	if snapshot.Version == "" {
		selected, err := g.deferred.MaterializeRequest()
		if err != nil {
			return nil, err
		}
		return &catalogProjection{bundle: selected, registration: g.catalogRegistration(selected)}, nil
	}
	if current := g.cachedCatalog(snapshot); current != nil {
		return current, nil
	}
	// Requests still read the catalog independently. Share the projection
	// work when they arrive together with the same new snapshot.
	g.catalogBuildMu.Lock()
	defer g.catalogBuildMu.Unlock()
	if current := g.cachedCatalog(snapshot); current != nil {
		return current, nil
	}
	selected, err := projectCatalog(*g.deferred, snapshot.Record)
	if err != nil {
		return nil, err
	}
	projection := &catalogProjection{
		version: snapshot.Version, record: bytes.Clone(snapshot.Record), bundle: selected,
		registration: g.catalogRegistration(selected),
	}
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

func projectCatalog(bundle config.Bundle, record []byte) (config.Bundle, error) {
	var catalog struct {
		Entries map[string]catalogEntry `json:"entries"`
	}
	if len(record) > 262144 || json.Unmarshal(record, &catalog) != nil {
		return config.Bundle{}, errors.New("invalid provider catalog")
	}
	selection, err := catalogSelection(bundle.Routing[0], catalog.Entries)
	if err != nil {
		return config.Bundle{}, err
	}
	bundle.Routing = []routing.Selection{selection}
	return bundle.MaterializeRequest()
}

func catalogSelection(source routing.Selection, entries map[string]catalogEntry) (routing.Selection, error) {
	selection := source
	selection.Candidates = nil
	tenant := ""
	for _, candidate := range source.Candidates {
		digest, err := candidate.Plan.Digest()
		if err != nil {
			return routing.Selection{}, err
		}
		entry, ok := entries[digest]
		if !ok {
			continue
		}
		// All concrete candidates for one original must use its tenant tariff.
		if len(selection.Candidates) != 0 && (entry.UserRates != selection.UserTokenRates || entry.Quote.Tenant != tenant) {
			return routing.Selection{}, errors.New("mixed catalog tariffs for original operation")
		}
		tenant = entry.Quote.Tenant
		selection.UserTokenRates = entry.UserRates
		candidate.Module, candidate.Capabilities = entry.Module, entry.Capabilities
		candidate.LatencyMillis = entry.Latency
		candidate.ProcurementRates, candidate.TokenBounds = entry.Quote.ProcurementRates, entry.Quote.TokenBounds
		selection.Candidates = append(selection.Candidates, candidate)
	}
	return selection, nil
}
