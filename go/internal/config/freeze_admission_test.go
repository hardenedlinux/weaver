// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package config

import (
	"reflect"
	"strings"
	"testing"
)

// Compare admission against the existing semantic oracle on arbitrary mutations.
// Copying data cannot turn invalid input into an admitted configuration.
func FuzzFrozenAdmissionPreservesValidation(f *testing.F) {
	f.Add(uint8(0), "changed", uint64(0))
	f.Add(uint8(8), "", uint64(1))
	f.Fuzz(func(t *testing.T, field uint8, text string, counter uint64) {
		if len(text) > 4096 {
			text = text[:4096]
		}
		input := sourceFixture(t)
		switch field % 10 {
		case 0:
			input.Governance.Family = text
		case 1:
			input.Governance.OpenNodes[0] = text
		case 2:
			input.Tasks[0].Family = text
		case 3:
			input.Plans[0].Body = text
		case 4:
			input.Plans[0].Ceiling = counter
		case 5:
			input.Publication.Fence = counter
		case 6:
			input.Tasks[0].ProviderProfile.MaxOutputTokens = counter
		case 7:
			input.Plans[0].Routes[0].Endpoint = text
		case 8:
			input.Publication.Policy = text
		case 9:
			input.Publication.ExpectedRevision = &counter
		}
		expected := input.Validate()
		result, err := FreezeBundle(input)
		if (err == nil) != (expected == nil) {
			t.Fatalf("admission changed: validate=%v freeze=%v", expected, err)
		}
		if err == nil && !reflect.DeepEqual(input, result) {
			t.Fatal("copy changed source semantics")
		}
	})
}

func TestFreezeRejectsOversizedSource(t *testing.T) {
	input := sourceFixture(t)
	input.Plans[0].Body = strings.Repeat("x", 8<<20)
	if _, err := FreezeBundle(input); err == nil {
		t.Fatal("oversized image copied/admitted")
	}
}
