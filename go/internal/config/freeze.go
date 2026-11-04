// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package config

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/routing"
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
	result.Publication = input.Publication.Clone()
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
	if err := result.chooseRoutes(); err != nil {
		return Bundle{}, err
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
	if r := input.Publication.Review; r != nil {
		if !strings([]string{r.Audience, r.SourceIdentityDigest, r.Signature, r.Delta, r.Review.Artifact, r.Review.Publication.OperationID, r.Review.Publication.Digest, string(r.Disposition)}) {
			return false
		}
		if p := r.Review.Parent; p != nil {
			if !strings([]string{p.PolicyDigest}) {
				return false
			}
			if p.SchemaDigest != nil && !add(*p.SchemaDigest) {
				return false
			}
		}
		if _, err := r.SigningDigest(); err != nil {
			return false
		}
		digest, err := input.Publication.Digest()
		if err != nil || r.Review.Publication.OperationID != input.Publication.OperationID || r.Review.Publication.Digest != digest {
			return false
		}
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
	if len(input.Routing) > 64 {
		return false
	}
	for _, choice := range input.Routing {
		if len(choice.Candidates) > 8 || !add(choice.Node) || !strings(choice.Required) || !strings(choice.AllowedModules) {
			return false
		}
		for _, candidate := range choice.Candidates {
			p := candidate.Plan
			if !add(candidate.Module) || !strings(candidate.Capabilities) ||
				!strings([]string{p.Family, p.Node, p.Profile, p.ProfileCommitment, p.Model, p.Body}) {
				return false
			}
			for _, route := range p.Routes {
				if !add(route.Target) || !add(route.Endpoint) {
					return false
				}
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

func (b *Bundle) chooseRoutes() error {
	if len(b.Routing) == 0 {
		return nil
	}
	if len(b.Tasks) != 1 || len(b.Plans) != 0 {
		return errors.New("routing source must declare one unmaterialized task")
	}
	task := &b.Tasks[0]
	if len(task.BodyDigests) != 0 || len(task.StreamContracts) != 0 {
		return errors.New("routing cannot replace original task commitments")
	}
	task.BodyDigests, task.StreamContracts = map[string]string{}, map[string]string{}
	for _, selection := range b.Routing {
		plan, err := routing.Select(*task, selection)
		if err != nil {
			return err
		}
		body := sha256.Sum256([]byte(plan.Body))
		digest, err := plan.Digest()
		if err != nil {
			return err
		}
		task.BodyDigests[plan.Node], task.StreamContracts[plan.Node] = hex.EncodeToString(body[:]), digest
		compiled, err := routing.CompileProvider(*task, plan, b.View())
		if err != nil {
			return err
		}
		b.Plans = append(b.Plans, compiled)
	}
	b.Routing = nil
	return nil
}
