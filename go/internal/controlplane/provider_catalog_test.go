// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"testing"
	"testing/quick"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/routing"
)

func TestCatalogSelectionUsesOnlyCurrentEntries(t *testing.T) {
	err := quick.Check(func(mask, firstLatency, secondLatency uint8) bool {
		source := routing.Selection{Candidates: []routing.Candidate{
			{Module: "source-a", Plan: v1.ProviderPlan{Model: "a"}},
			{Module: "source-b", Plan: v1.ProviderPlan{Model: "b"}},
		}}
		entries := map[string]catalogEntry{}
		latencies := []uint8{firstLatency, secondLatency}
		var want []routing.Candidate
		for i, candidate := range source.Candidates {
			if mask&(1<<i) == 0 {
				continue
			}
			digest, err := candidate.Plan.Digest()
			if err != nil {
				return false
			}
			entry := catalogEntry{Module: "authoritative", Latency: 1 + uint64(latencies[i])}
			entries[digest] = entry
			candidate.Module, candidate.LatencyMillis = entry.Module, entry.Latency
			want = append(want, candidate)
		}
		selected, err := catalogSelection(source, entries)
		if err != nil || len(selected.Candidates) != len(want) {
			return false
		}
		for i, candidate := range selected.Candidates {
			if candidate.Module != want[i].Module || candidate.Plan.Model != want[i].Plan.Model ||
				candidate.LatencyMillis != want[i].LatencyMillis {
				return false
			}
		}
		return source.Candidates[0].Module == "source-a" && source.Candidates[1].Module == "source-b"
	}, &quick.Config{MaxCount: 128})
	if err != nil {
		t.Fatal(err)
	}
}
