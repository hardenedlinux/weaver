package routing

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"strings"
	"testing"
)

func providerOriginal(t testing.TB) (v1.Task, v1.ProviderPlan) {
	t.Helper()
	p := v1.ProviderPlan{Family: "f", Node: "infer", Profile: "p", Model: "model-a", Body: `{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":32}`, Routes: []v1.ProviderRoute{{Target: "primary", Endpoint: "https://primary.invalid/v1/chat/completions"}, {Target: "backup", Endpoint: "https://backup.invalid/v1/chat/completions"}}, Ceiling: 4}
	profile := &v1.ProviderProfile{ID: "p", Protocol: v1.ChatTextSSE, MaxOutputTokens: 4096, MaxMessages: 64, MaxBodyBytes: 1 << 20}
	p.ProfileCommitment, _ = profile.Digest()
	digest, err := p.Digest()
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(p.Body))
	task := v1.Task{ProviderProfile: profile, Family: "f", Profile: "p", Nodes: []string{"infer"}, Targets: []string{"primary", "backup"}, Endpoints: map[string]string{"primary": p.Routes[0].Endpoint, "backup": p.Routes[1].Endpoint}, BodyDigests: map[string]string{"infer": hex.EncodeToString(sum[:])}, StreamContracts: map[string]string{"infer": digest}, Models: []string{"model-a"}, NodeCostBounds: map[string]uint64{"infer": 4}, Budget: 8}
	return task, p
}
func TestProviderRoutingCannotRewriteOriginalContract(t *testing.T) {
	task, original := providerOriginal(t)
	if _, err := CompileProvider(task, original, v1.View{Revision: 3, Fence: 7}); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*v1.ProviderPlan){func(p *v1.ProviderPlan) { p.Profile = "forged" }, func(p *v1.ProviderPlan) { p.Body += " " }, func(p *v1.ProviderPlan) { p.Ceiling = 8 }, func(p *v1.ProviderPlan) { p.Routes[0], p.Routes[1] = p.Routes[1], p.Routes[0] }} {
		p := original
		p.Routes = append([]v1.ProviderRoute(nil), original.Routes...)
		mutate(&p)
		if _, err := CompileProvider(task, p, v1.View{}); err == nil {
			t.Fatal("mutated provider commitment accepted")
		}
	}
}

func TestProviderRoutingRejectsCompetingSourceCommittedLimits(t *testing.T) {
	task, p := providerOriginal(t)
	p.Body = `{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":32,"max_tokens":1000000}`
	digest, err := p.Digest()
	if err != nil {
		t.Fatal(err)
	}
	body := sha256.Sum256([]byte(p.Body))
	task.BodyDigests[p.Node] = hex.EncodeToString(body[:])
	task.StreamContracts[p.Node] = digest
	if _, err := CompileProvider(task, p, v1.View{}); err == nil {
		t.Fatal("source commitment incorrectly qualified competing provider limits")
	}
}

func FuzzProviderRequestBounds(f *testing.F) {
	f.Add(uint8(1), uint64(32), uint8(1))
	f.Add(uint8(2), uint64(4096), uint8(1))
	f.Add(uint8(3), uint64(4097), uint8(1))
	f.Add(uint8(0), uint64(0), uint8(2))
	f.Fuzz(func(t *testing.T, presence uint8, tokens uint64, choices uint8) {
		task, plan := providerOriginal(t)
		body := map[string]any{"model": plan.Model, "stream": true, "messages": []any{map[string]any{"role": "user", "content": "hello"}}, "n": choices}
		modern, legacy := presence&1 != 0, presence&2 != 0
		if modern {
			body["max_completion_tokens"] = tokens
		}
		if legacy {
			body["max_tokens"] = tokens
		}
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		plan.Body = string(encoded)
		digest, err := plan.Digest()
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(encoded)
		task.BodyDigests[plan.Node] = hex.EncodeToString(sum[:])
		task.StreamContracts[plan.Node] = digest
		_, err = CompileProvider(task, plan, v1.View{})
		want := modern != legacy && tokens > 0 && tokens <= 4096 && choices == 1
		if (err == nil) != want {
			t.Fatalf("provider request admission disagrees with bounds: %v", err)
		}
	})
}

func TestProviderRequestShapeRejectsUnboundedValues(t *testing.T) {
	task, plan := providerOriginal(t)
	for _, value := range []string{`0`, `-1`, `4097`, `32.5`, `"32"`, `null`} {
		body, err := v1.Decode[map[string]json.RawMessage]([]byte(plan.Body))
		if err != nil {
			t.Fatal(err)
		}
		body["max_completion_tokens"] = []byte(value)
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := task.ProviderProfile.RequestFacts(string(encoded)); err == nil {
			t.Fatalf("invalid cap accepted: %s", value)
		}
	}
	for _, messages := range []string{`[]`, `null`, `{}`, `"hello"`, "[" + strings.TrimSuffix(strings.Repeat(`{"role":"user","content":"hello"},`, 65), ",") + "]"} {
		body, err := v1.Decode[map[string]json.RawMessage]([]byte(plan.Body))
		if err != nil {
			t.Fatal(err)
		}
		body["messages"] = []byte(messages)
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := task.ProviderProfile.RequestFacts(string(encoded)); err == nil {
			t.Fatalf("unbounded messages accepted: %s", messages)
		}
	}
	if _, err := task.ProviderProfile.RequestFacts(strings.Repeat(" ", 1<<20) + plan.Body); err == nil {
		t.Fatal("oversized request accepted")
	}
}
func FuzzProviderPlanCannotExpandAuthority(f *testing.F) {
	f.Add("forged", uint64(9), uint8(0))
	f.Add("p", uint64(4), uint8(1))
	f.Fuzz(func(t *testing.T, profile string, ceiling uint64, order uint8) {
		task, p := providerOriginal(t)
		p.Profile = profile
		p.Ceiling = ceiling
		if order%2 == 1 {
			p.Routes[0], p.Routes[1] = p.Routes[1], p.Routes[0]
		}
		result, err := CompileProvider(task, p, v1.View{})
		if err == nil && (result.Profile != "p" || result.Ceiling != 4 || result.Routes[0].Target != "primary" || result.Routes[1].Target != "backup") {
			t.Fatal("routing expanded original authority")
		}
	})
}
