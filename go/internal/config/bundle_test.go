// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package config

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"gopkg.in/yaml.v3"
)

func sourceFixture(t testing.TB) Bundle {
	t.Helper()
	profile := &v1.ProviderProfile{ID: "p", Protocol: v1.ChatTextSSE, MaxOutputTokens: 32, MaxMessages: 1, MaxBodyBytes: 4096}
	commitment, err := profile.Digest()
	if err != nil {
		t.Fatal(err)
	}
	p := v1.ProviderPlan{Family: "f", Node: "infer", Profile: "p", ProfileCommitment: commitment, Model: "m", Body: `{"model":"m","stream":true,"messages":[{"role":"user","content":"hello"}],"max_tokens":8}`, Routes: []v1.ProviderRoute{{Target: "primary", Endpoint: "https://provider.invalid/v1/chat/completions"}}, Ceiling: 4}
	digest, err := p.Digest()
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(p.Body))
	task := v1.Task{Family: "f", Principal: "alice", Profile: "p", ProviderProfile: profile, Nodes: []string{"infer"}, Targets: []string{"primary"}, Endpoints: map[string]string{"primary": p.Routes[0].Endpoint}, BodyDigests: map[string]string{"infer": hex.EncodeToString(sum[:])}, StreamContracts: map[string]string{"infer": digest}, NodeCostBounds: map[string]uint64{"infer": 4}, Models: []string{"m"}, Budget: 8}
	return Bundle{Governance: Governance{Schema: "agentic-ai-lab.loop-governor.v1", Family: "f", OpenNodes: []string{"infer"}}, Tasks: []v1.Task{task}, Plans: []v1.ProviderPlan{p}, Publication: v1.Publication{OperationID: "source", Fence: 1, Policy: `permit(principal,action,resource);`, Schema: `{}`}}
}
func TestBundleFormatsPreserveOriginalGovernorAndTask(t *testing.T) {
	b := sourceFixture(t)
	data, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	left, err := DecodeBundle(data, ProfileJSON)
	if err != nil {
		t.Fatal(err)
	}
	var v any
	if err = yaml.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	data, err = yaml.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	right, err := DecodeBundle(data, ProfileYAML)
	if err != nil || !reflect.DeepEqual(left, right) {
		t.Fatal("source format changes original semantics", err)
	}
}
func TestBundleRejectsSelectionAndCommitmentSubstitution(t *testing.T) {
	for _, change := range []func(*Bundle){
		func(b *Bundle) { b.Governance.Schema = "custom-governor" }, func(b *Bundle) { b.Governance.Family = "new-family" }, func(b *Bundle) { b.Governance.OpenNodes = []string{"forged"} },
		func(b *Bundle) { b.Governance.OpenNodes = append(b.Governance.OpenNodes, "infer") }, func(b *Bundle) { b.Tasks[0].Nodes = append(b.Tasks[0].Nodes, "forged") },
		func(b *Bundle) { b.Plans[0].Body += " " }, func(b *Bundle) { b.Plans[0].Ceiling++ }, func(b *Bundle) { b.Plans[0].Routes[0].Endpoint = "https://other.invalid/" },
	} {
		b := sourceFixture(t)
		change(&b)
		if b.Validate() == nil {
			t.Fatal("substituted source contract accepted")
		}
	}
}
func TestBundleRejectsAmbiguousAndExecutableData(t *testing.T) {
	b := sourceFixture(t)
	data, _ := json.Marshal(b)
	for _, raw := range []string{strings.Replace(string(data), `"governance":`, `"extra":true,"governance":`, 1), strings.Replace(string(data), `"tasks":`, `"tasks":[],"tasks":`, 1), string(data) + string(data), `(make-loop-governor 'forged)`} {
		if _, err := DecodeBundle([]byte(raw), ProfileJSON); err == nil {
			t.Fatal("ambiguous source JSON accepted")
		}
	}
	var value any
	yaml.Unmarshal(data, &value)
	encoded, _ := yaml.Marshal(value)
	for _, raw := range []string{string(encoded) + "---\n{}", string(encoded) + "tasks: []\n", strings.Replace(string(encoded), "budget: 8", "budget: 8.0", 1), strings.Replace(string(encoded), "budget: 8", "budget: 0x8", 1), strings.Replace(string(encoded), "family: f", "family: &alias f", 1)} {
		if _, err := DecodeBundle([]byte(raw), ProfileYAML); err == nil {
			t.Fatal("ambiguous source YAML accepted")
		}
	}
}
func FuzzSourceBundleCannotExpandOriginalSelection(f *testing.F) {
	data, _ := json.Marshal(sourceFixture(f))
	f.Add(string(data), false)
	f.Add("tasks: *alias", true)
	f.Fuzz(func(t *testing.T, raw string, yamlFormat bool) {
		format := ProfileJSON
		if yamlFormat {
			format = ProfileYAML
		}
		b, err := DecodeBundle([]byte(raw), format)
		if err != nil {
			return
		}
		b.Plans[0].Body += " "
		if b.Validate() == nil {
			t.Fatal("source body changed without original commitment")
		}
	})
}
