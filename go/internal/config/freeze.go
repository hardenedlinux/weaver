// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package config

import (
	"errors"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"maps"
	"slices"
)

// FreezeBundle takes an independent validated copy for private control-plane
// ownership. JSON/YAML remain ingress formats, not an internal cloning protocol.
func FreezeBundle(input Bundle) (Bundle, error) {
	// Copy only bounded input, then validate the independent image once.
	// Callers must keep input stable during this synchronous copy.
	if !sourceTextBound(input) {
		return Bundle{}, errors.New("typed source text bound")
	}
	result := input
	result.Governance.OpenNodes = slices.Clone(input.Governance.OpenNodes)
	if input.Publication.ExpectedRevision != nil {
		revision := *input.Publication.ExpectedRevision
		result.Publication.ExpectedRevision = &revision
	}
	result.Tasks = make([]v1.Task, len(input.Tasks))
	for index, t := range input.Tasks {
		copy := t
		copy.Nodes = slices.Clone(t.Nodes)
		copy.Targets = slices.Clone(t.Targets)
		copy.Models = slices.Clone(t.Models)
		copy.Endpoints = maps.Clone(t.Endpoints)
		copy.BodyDigests = maps.Clone(t.BodyDigests)
		copy.NodeCostBounds = maps.Clone(t.NodeCostBounds)
		copy.StreamContracts = maps.Clone(t.StreamContracts)
		if t.ProviderProfile != nil {
			profile := *t.ProviderProfile
			copy.ProviderProfile = &profile
		}
		result.Tasks[index] = copy
	}
	result.Plans = make([]v1.ProviderPlan, len(input.Plans))
	for index, p := range input.Plans {
		copy := p
		copy.Routes = slices.Clone(p.Routes)
		result.Plans[index] = copy
	}
	if err := result.Validate(); err != nil {
		return Bundle{}, err
	}
	return result, nil
}

// Bounded typed storage is separate from encoded JSON/YAML and RPC frame bounds.
func sourceTextBound(input Bundle) bool {
	remaining := 8 << 20
	add := func(value string) bool {
		if len(value) >= remaining {
			return false
		}
		// Charge one structural slot too; empty strings cannot create an
		// unbounded cloning workload at zero text cost.
		remaining -= len(value) + 1
		return true
	}
	strings := func(values []string) bool {
		for _, value := range values {
			if !add(value) {
				return false
			}
		}
		return true
	}
	mapping := func(values map[string]string) bool {
		for key, value := range values {
			if !add(key) || !add(value) {
				return false
			}
		}
		return true
	}
	if !strings([]string{input.Governance.Schema, input.Governance.Family, input.Publication.OperationID, input.Publication.Policy, input.Publication.Schema}) || !strings(input.Governance.OpenNodes) {
		return false
	}
	for _, t := range input.Tasks {
		if !strings([]string{t.Family, t.Principal, t.Profile}) || !strings(t.Nodes) || !strings(t.Targets) || !strings(t.Models) || !mapping(t.Endpoints) || !mapping(t.BodyDigests) || !mapping(t.StreamContracts) {
			return false
		}
		for key := range t.NodeCostBounds {
			if !add(key) {
				return false
			}
		}
		if p := t.ProviderProfile; p != nil {
			if !strings([]string{p.ID, p.Protocol}) {
				return false
			}
		}
	}
	for _, p := range input.Plans {
		if !strings([]string{p.Family, p.Node, p.Profile, p.ProfileCommitment, p.Model, p.Body}) {
			return false
		}
		for _, r := range p.Routes {
			if !strings([]string{r.Target, r.Endpoint}) {
				return false
			}
		}
	}
	return true
}
