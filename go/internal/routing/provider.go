// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package routing

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"math"
	"net/url"
	"slices"
	"strings"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

// CompileProvider preserves the complete source-authorized routing order. Runtime
// credential availability and Cedar choose a route only inside Rust, before consumption.
func CompileProvider(task v1.Task, p v1.ProviderPlan, view v1.View) (v1.ProviderPlan, error) {
	var zero v1.ProviderPlan
	if task.ProviderProfile == nil {
		return zero, errors.New("source provider profile required")
	}
	profileDigest, err := task.ProviderProfile.Digest()
	if err != nil || task.ProviderProfile.ID != task.Profile || p.ProfileCommitment != profileDigest {
		return zero, errors.New("original provider profile commitment")
	}
	facts, err := task.ProviderProfile.RequestFacts(p.Body)
	if err != nil {
		return zero, err
	}
	if len(p.Body) > 1<<20 {
		return zero, errors.New("provider body bound")
	}
	digest, err := p.Digest()
	if err != nil {
		return zero, err
	}
	if facts.Model != p.Model {
		return zero, errors.New("stream model mismatch")
	}
	sum := sha256.Sum256([]byte(p.Body))
	if p.Family != task.Family || p.Profile != task.Profile || !slices.Contains(task.Nodes, p.Node) || !slices.Contains(task.Models, p.Model) || task.BodyDigests[p.Node] != hex.EncodeToString(sum[:]) || task.StreamContracts[p.Node] != digest {
		return zero, errors.New("original provider commitment mismatch")
	}
	if len(p.Routes) == 0 || len(p.Routes) > 8 || p.Ceiling == 0 || p.Ceiling > task.Budget || p.Ceiling > math.MaxInt64 || task.NodeCostBounds[p.Node] == 0 || task.NodeCostBounds[p.Node] > p.Ceiling || view.Revision > math.MaxInt64 || view.Fence > math.MaxInt64 {
		return zero, errors.New("provider resource bounds")
	}
	seen := map[string]bool{}
	for _, route := range p.Routes {
		parsed, err := url.Parse(route.Endpoint)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" || !slices.Contains(task.Targets, route.Target) || task.Endpoints[route.Target] != route.Endpoint || seen[route.Target] {
			return zero, errors.New("unregistered provider route")
		}
		if task.ProviderProfile.Protocol == v1.AnthropicMessagesSSE &&
			(parsed.EscapedPath() != "/v1/messages" || parsed.RawQuery != "" || parsed.ForceQuery || strings.Contains(route.Endpoint, "#")) {
			return zero, errors.New("Anthropic Messages endpoint required")
		}
		seen[route.Target] = true
	}
	p.Revision = view.Revision
	p.Fence = view.Fence
	// Retain the validated order independently of later caller mutations.
	// Input must remain stable throughout this synchronous validation/copy.
	p.Routes = slices.Clone(p.Routes)
	return p, nil
}
