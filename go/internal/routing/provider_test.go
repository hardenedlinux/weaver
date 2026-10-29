package routing

import (
	"crypto/sha256"
	"encoding/hex"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"testing"
)

func providerOriginal(t testing.TB) (v1.Task, v1.ProviderPlan) {
	t.Helper()
	p := v1.ProviderPlan{Family: "f", Node: "infer", Profile: "p", Model: "model-a", Body: `{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":32}`, Routes: []v1.ProviderRoute{{Target: "primary", Endpoint: "https://primary.invalid/v1/chat/completions"}, {Target: "backup", Endpoint: "https://backup.invalid/v1/chat/completions"}}, Ceiling: 4}
	digest, err := p.Digest()
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(p.Body))
	task := v1.Task{Family: "f", Profile: "p", Nodes: []string{"infer"}, Targets: []string{"primary", "backup"}, Endpoints: map[string]string{"primary": p.Routes[0].Endpoint, "backup": p.Routes[1].Endpoint}, BodyDigests: map[string]string{"infer": hex.EncodeToString(sum[:])}, StreamContracts: map[string]string{"infer": digest}, Models: []string{"model-a"}, NodeCostBounds: map[string]uint64{"infer": 4}, Budget: 8}
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
