// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package config

import (
	"slices"
	"strings"
	"testing"
	"testing/quick"

	"github.com/HardenedLinux/weaver/go/internal/routing"
)

func TestRoutingMaterializesOneOriginalPlan(t *testing.T) {
	err := quick.Check(func(reverse, cheapCapable, cheapFast bool) bool {
		bundle := sourceFixture(t)
		cheap, expensive := bundle.Plans[0], bundle.Plans[0]
		expensive.Model = "premium"
		expensive.Body = strings.Replace(expensive.Body, `"model":"m"`, `"model":"premium"`, 1)
		bundle.Plans = nil
		bundle.Tasks[0].BodyDigests, bundle.Tasks[0].StreamContracts = nil, nil
		bundle.Tasks[0].Models = []string{"m", "premium"}
		fast := uint64(200)
		if cheapFast {
			fast = 20
		}
		var capabilities []string
		if cheapCapable {
			capabilities = []string{"structured"}
		}
		options := []routing.Candidate{
			{Module: "basic", Capabilities: capabilities, LatencyMillis: fast, ProcurementRates: [4]uint64{10}, TokenBounds: [4]uint64{16, 0, 0, 8}, Plan: cheap},
			{Module: "premium", Capabilities: []string{"structured"}, LatencyMillis: 40, ProcurementRates: [4]uint64{1_000_000}, TokenBounds: [4]uint64{16, 0, 0, 8}, Plan: expensive},
		}
		if reverse {
			slices.Reverse(options)
		}
		bundle.Routing = []routing.Selection{{Node: "infer", AllowedModules: []string{"basic", "premium"},
			Required: []string{"structured"}, MaxLatencyMillis: 100, MaxProcurementCost: 20,
			UserTokenRates: [4]uint64{100_000}, Candidates: options}}
		frozen, err := FreezeBundle(bundle)
		if err != nil || len(frozen.Plans) != 1 {
			t.Logf("routing: %v", err)
			return false
		}
		want := "premium"
		if cheapCapable && cheapFast {
			want = "m"
		}
		digest, err := frozen.Plans[0].Digest()
		return err == nil && frozen.Plans[0].Model == want &&
			frozen.Tasks[0].StreamContracts["infer"] == digest && len(frozen.Routing) == 0
	}, &quick.Config{MaxCount: 64})
	if err != nil {
		t.Fatal(err)
	}
}
