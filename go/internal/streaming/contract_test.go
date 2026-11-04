// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package streaming

import (
	contract "github.com/HardenedLinux/weaver/go/api/v1"
	"testing"
)

func fixture() (contract.Task, Contract) {
	task := contract.Task{Family: "f", Principal: "alice", Profile: "p", Nodes: []string{"emit"}, Targets: []string{"t"}, BodyDigests: map[string]string{"emit": "input"}, NodeCostBounds: map[string]uint64{"emit": 8}, Budget: 10}
	c := Contract{Family: "f", Node: "emit", Profile: "p", Target: "t", InputDigest: "input", Destination: "tcp://127.0.0.1:9000", Messages: []MessageRule{{ID: "m0", MaxBytes: 32, CostBound: 4}, {ID: "m1", MaxBytes: 32, CostBound: 4}}}
	digest, _ := c.Digest()
	task.StreamContracts = map[string]string{"emit": digest}
	return task, c
}
func TestOriginalMessageAndCostRemainBound(t *testing.T) {
	task, c := fixture()
	p, err := Compile(task, c, "m0", "data", 99, contract.View{Revision: 2, Fence: 3})
	if err != nil || p.Ceiling != 10 || p.Message != "m0" || p.Family != "f" {
		t.Fatalf("invalid refinement: %+v %v", p, err)
	}
	for _, id := range []string{"new-nonce", "new-family", "invented"} {
		if _, err := Compile(task, c, id, "data", 4, contract.View{}); err == nil {
			t.Fatal("invented identity")
		}
	}
	if _, err := Compile(task, c, "m0", "data", 3, contract.View{}); err == nil {
		t.Fatal("underreservation")
	}
	c.InputDigest = "forged"
	if _, err := Compile(task, c, "m0", "data", 4, contract.View{}); err == nil {
		t.Fatal("forged input")
	}
}
func TestProviderProfileCannotUseRawStreamPath(t *testing.T) {
	task, c := fixture()
	task.ProviderProfile = &contract.ProviderProfile{ID: task.Profile, Protocol: contract.ChatTextSSE, MaxOutputTokens: 4096, MaxMessages: 64, MaxBodyBytes: 1 << 20}
	if _, err := Compile(task, c, "m0", "data", 4, contract.View{}); err == nil {
		t.Fatal("provider semantic contract bypassed by raw stream emission")
	}
}
func FuzzMessageBounds(f *testing.F) {
	f.Add("hello", uint64(4))
	f.Add("", uint64(0))
	f.Fuzz(func(t *testing.T, payload string, ceiling uint64) {
		task, c := fixture()
		p, err := Compile(task, c, "m0", payload, ceiling, contract.View{})
		if err == nil && (p.Ceiling > task.Budget || p.Ceiling < 4 || len(p.Payload) > 32 || p.Message != "m0") {
			t.Fatal("original bounds escaped")
		}
	})
}
