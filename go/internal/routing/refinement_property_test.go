package routing

import (
	"math"
	"testing"

	contract "github.com/HardenedLinux/weaver/go/api/v1"
)

// The native framework owns generation, minimization and corpus replay.
// Checking successful refinement as well as rejection prevents all-deny passes.
func FuzzRoutingRefinement(f *testing.F) {
	for _, seed := range []struct{ budget, ceiling, cost uint64 }{
		{50, 99, 1}, {0, 1, 1}, {50, 0, 1}, {50, 50, 0},
		{50, 49, 50}, {math.MaxInt64, math.MaxUint64, 1},
		{math.MaxUint64, math.MaxUint64, 1},
	} {
		f.Add(seed.budget, seed.ceiling, seed.cost, uint64(3), uint64(9), uint8(0))
	}
	for bit := uint8(0); bit < 6; bit++ {
		f.Add(uint64(50), uint64(99), uint64(1), uint64(3), uint64(9), uint8(1<<bit))
	}
	f.Fuzz(func(t *testing.T, budget, ceiling, cost, revision, fence uint64, mutation uint8) {
		task, request := fixture()
		task.Budget, request.Ceiling = budget, ceiling
		task.NodeCostBounds["infer"] = cost
		if mutation&1 != 0 {
			request.Node = "unclaimed-node"
		}
		if mutation&2 != 0 {
			request.Model = "unclaimed-model"
		}
		if mutation&4 != 0 {
			request.Body += " " // Valid JSON, different original byte commitment.
		}
		if mutation&8 != 0 {
			request.Targets = []string{"forged"}
		}
		if mutation&16 != 0 {
			delete(task.Endpoints, "primary")
		}
		if mutation&32 != 0 {
			task.ProviderProfile = &contract.ProviderProfile{}
		}
		proposal, err := Compile(task, request, contract.View{Revision: revision, Fence: fence})
		wantAllowed := mutation&63 == 0 && budget > 0 && budget <= math.MaxInt64 &&
			ceiling > 0 && cost > 0 && cost <= budget && cost <= ceiling
		if (err == nil) != wantAllowed {
			t.Fatalf("authorization outcome: allowed=%t want=%t error=%v", err == nil, wantAllowed, err)
		}
		if !wantAllowed {
			if proposal != (contract.Proposal{}) {
				t.Fatalf("rejected request retained a proposal: %+v", proposal)
			}
			return
		}
		want := contract.Proposal{
			Family: task.Family, Node: "infer", Profile: task.Profile,
			Target: "primary", Endpoint: task.Endpoints["primary"],
			Model: "model-a", Body: request.Body, Ceiling: min(budget, ceiling),
			Revision: revision, Fence: fence,
		}
		if proposal != want {
			t.Fatalf("original authority changed: got=%+v want=%+v", proposal, want)
		}
	})
}
