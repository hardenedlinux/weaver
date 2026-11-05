// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"context"
	"encoding/json"
	"errors"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
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

func (g *Gateway) materializeProvider(ctx context.Context) (config.Bundle, string, error) {
	snapshot, err := g.source.RPC.InspectProviderCatalog(g.source.Context(ctx), &pb.Empty{})
	if err != nil {
		return config.Bundle{}, "", err
	}
	bundle := *g.deferred
	if snapshot.Version != "" {
		var catalog struct {
			Entries map[string]catalogEntry `json:"entries"`
		}
		if len(snapshot.Record) > 262144 || json.Unmarshal(snapshot.Record, &catalog) != nil {
			return config.Bundle{}, "", errors.New("invalid provider catalog")
		}
		selection, err := catalogSelection(bundle.Routing[0], catalog.Entries)
		if err != nil {
			return config.Bundle{}, "", err
		}
		bundle.Routing = []routing.Selection{selection}
	}
	selected, err := bundle.MaterializeRequest()
	return selected, snapshot.Version, err
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
