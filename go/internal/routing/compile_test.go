// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package routing

import (
	"crypto/sha256"
	"encoding/hex"
	contract "github.com/HardenedLinux/weaver/go/api/v1"
	"testing"
)

func fixture() (contract.Task, contract.Request) {
	body := `{"model":"model-a","messages":[],"stream":false}`
	digest := sha256.Sum256([]byte(body))
	return contract.Task{Family: "family", Principal: "alice", Profile: "profile", Nodes: []string{"infer"}, Targets: []string{"primary"}, Endpoints: map[string]string{"primary": "https://example.invalid/v1/chat/completions"}, BodyDigests: map[string]string{"infer": hex.EncodeToString(digest[:])}, Models: []string{"model-a"}, NodeCostBounds: map[string]uint64{"infer": 1}, Budget: 50}, contract.Request{Node: "infer", Targets: []string{"forged", "primary"}, Model: "model-a", Body: body, Ceiling: 99}
}

func TestRefinement(t *testing.T) {
	task, request := fixture()
	p, err := Compile(task, request, contract.View{Revision: 3, Fence: 9})
	if err != nil || p.Ceiling != 50 || p.Target != "primary" || p.Family != task.Family || p.Revision != 3 {
		t.Fatalf("invalid refinement: %+v %v", p, err)
	}
}
func TestProviderProfileCannotUseUntypedRequestPath(t *testing.T) {
	task, request := fixture()
	task.ProviderProfile = &contract.ProviderProfile{ID: task.Profile, Protocol: contract.ChatTextSSE, MaxOutputTokens: 4096, MaxMessages: 64, MaxBodyBytes: 1 << 20}
	if _, err := Compile(task, request, contract.View{}); err == nil {
		t.Fatal("provider semantic contract bypassed by an untyped request")
	}
}

func FuzzCeilingNeverExpands(f *testing.F) {
	f.Add(uint64(1))
	f.Add(uint64(50))
	f.Add(^uint64(0))
	f.Fuzz(func(t *testing.T, ceiling uint64) {
		task, request := fixture()
		request.Ceiling = ceiling
		p, err := Compile(task, request, contract.View{})
		if err == nil && (p.Ceiling > task.Budget || p.Ceiling > ceiling || p.Ceiling == 0) {
			t.Fatal("budget refinement violated")
		}
	})
}

func TestForgedBodyAndNodeFail(t *testing.T) {
	task, request := fixture()
	request.Body = `{"model":"model-a","messages":["changed"]}`
	if _, err := Compile(task, request, contract.View{}); err == nil {
		t.Fatal("uncommitted body accepted")
	}
	_, request = fixture()
	request.Node = "invented"
	if _, err := Compile(task, request, contract.View{}); err == nil {
		t.Fatal("invented routine node accepted")
	}
}

func TestOriginalCostBoundCannotBeLowered(t *testing.T) {
	task, request := fixture()
	task.NodeCostBounds["infer"] = 20
	request.Ceiling = 19
	if _, err := Compile(task, request, contract.View{}); err == nil {
		t.Fatal("original cost was underreserved")
	}
}
