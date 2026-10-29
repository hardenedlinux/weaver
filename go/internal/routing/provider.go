package routing

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"net/url"
	"slices"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

// CompileProvider preserves the complete source-authorized routing order. Runtime
// credential availability and Cedar choose a route only inside Rust, before consumption.
func CompileProvider(task v1.Task, p v1.ProviderPlan, view v1.View) (v1.ProviderPlan, error) {
	var zero v1.ProviderPlan
	if len(p.Body) > 1<<20 {
		return zero, errors.New("provider body bound")
	}
	digest, err := p.Digest()
	if err != nil {
		return zero, err
	}
	body, err := v1.Decode[map[string]json.RawMessage]([]byte(p.Body))
	if err != nil {
		return zero, err
	}
	if err := providerBounds(body, len(p.Body)); err != nil {
		return zero, err
	}
	var model string
	var streaming bool
	if json.Unmarshal(body["model"], &model) != nil || model != p.Model || json.Unmarshal(body["stream"], &streaming) != nil || !streaming {
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
		seen[route.Target] = true
	}
	for _, key := range []string{"tools", "tool_choice", "functions", "function_call"} {
		if _, ok := body[key]; ok {
			return zero, errors.New("tool profile unavailable")
		}
	}
	p.Revision = view.Revision
	p.Fence = view.Fence
	return p, nil
}

// Go rejects unsupported proposals early; Rust independently repeats admission.
func providerBounds(body map[string]json.RawMessage, bytes int) error {
	modern, hasModern := body["max_completion_tokens"]
	legacy, hasLegacy := body["max_tokens"]
	if bytes > 1048576 || hasModern == hasLegacy {
		return errors.New("one bounded provider token limit required")
	}
	limit := modern
	if hasLegacy {
		limit = legacy
	}
	var tokens uint64
	if json.Unmarshal(limit, &tokens) != nil || tokens == 0 || tokens > 4096 {
		return errors.New("provider token limit exceeded")
	}
	var messages []json.RawMessage
	if json.Unmarshal(body["messages"], &messages) != nil || len(messages) == 0 || len(messages) > 64 {
		return errors.New("bounded provider messages required")
	}
	if value, ok := body["n"]; ok {
		var choices uint64
		if json.Unmarshal(value, &choices) != nil || choices != 1 {
			return errors.New("single provider choice required")
		}
	}
	return nil
}
