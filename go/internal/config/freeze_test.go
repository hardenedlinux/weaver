// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package config

import "testing"

func FuzzFrozenSourceDoesNotFollowCallerMutation(f *testing.F) {
	f.Add(uint8(0))
	f.Add(uint8(8))
	f.Fuzz(func(t *testing.T, field uint8) {
		original := sourceFixture(t)
		revision := uint64(0)
		original.Publication.ExpectedRevision = &revision
		frozen, err := FreezeBundle(original)
		if err != nil {
			t.Fatal(err)
		}
		switch field % 9 {
		case 0:
			original.Governance.OpenNodes[0] = "changed"
		case 1:
			original.Tasks[0].Nodes[0] = "changed"
		case 2:
			original.Tasks[0].Targets[0] = "changed"
		case 3:
			original.Tasks[0].Models[0] = "changed"
		case 4:
			original.Tasks[0].Endpoints["primary"] = "https://changed.invalid"
		case 5:
			original.Tasks[0].NodeCostBounds["infer"] = 999
		case 6:
			original.Tasks[0].ProviderProfile.MaxOutputTokens = 1
		case 7:
			original.Plans[0].Routes[0].Endpoint = "https://changed.invalid"
		case 8:
			*original.Publication.ExpectedRevision = 99
		}
		if err := frozen.Validate(); err != nil || *frozen.Publication.ExpectedRevision != 0 || frozen.Tasks[0].ProviderProfile.MaxOutputTokens != 32 {
			t.Fatal("frozen source followed caller storage", err)
		}
	})
}
