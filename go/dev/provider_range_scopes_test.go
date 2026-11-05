// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"math/rand"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"testing/quick"
	"time"
)

type rangeScopeSample struct {
	phase          string
	family         string
	arrival, grant uint64
	wait, hold     time.Duration
}

func BenchmarkProviderSharedRangeScopes(b *testing.B) {
	benchmarkProviderSharedLongTail(b, true)
}

func readRangeScopes(b *testing.B, f *fixture) map[string][]rangeScopeSample {
	b.Helper()
	log, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		b.Fatal(err)
	}
	result := make(map[string][]rangeScopeSample)
	seen := make(map[uint64]bool)
	for _, line := range strings.Split(string(log), "\n") {
		raw, ok := strings.CutPrefix(line, "weaver-provider-scope ")
		if !ok {
			continue
		}
		fields := strings.Fields(raw)
		if len(fields) == 0 || result[fields[0]] != nil {
			b.Fatalf("missing or duplicate provider scope observation: %q", raw)
		}
		family := fields[0]
		for _, field := range fields[1:] {
			parts := strings.Split(field, ":")
			if len(parts) != 5 || (parts[0] != "prepare" && parts[0] != "queue" && parts[0] != "other") {
				b.Fatalf("invalid stripe sample: %q", field)
			}
			var n [4]uint64
			for i, value := range parts[1:] {
				n[i], err = strconv.ParseUint(value, 10, 63)
				if err != nil {
					b.Fatalf("invalid stripe sample value: %q", value)
				}
			}
			if n[0] == 0 || n[0] >= n[1] || seen[n[0]] || seen[n[1]] {
				b.Fatalf("invalid or duplicate stripe ordinal: %q", field)
			}
			seen[n[0]], seen[n[1]] = true, true
			result[family] = append(result[family], rangeScopeSample{
				phase: parts[0], family: family, arrival: n[0], grant: n[1],
				wait: time.Duration(n[2]), hold: time.Duration(n[3]),
			})
		}
	}
	return result
}

// A later conflicting ticket receives custody before an older registered one.
// This statistic is evaluated only within a shared-root wave.
func rangeScopeOvertakes(wave []rangeScopeSample, older rangeScopeSample) int {
	count := 0
	for _, younger := range wave {
		if younger.family != older.family && older.arrival < younger.arrival && younger.grant < older.grant {
			count++
		}
	}
	return count
}

func TestProviderScopeFairnessCountsArrivalGrantInversions(t *testing.T) {
	property := func(seed uint64, count uint8) bool {
		n := int(count%24) + 1
		order := rand.New(rand.NewSource(int64(seed))).Perm(n)
		wave := make([]rangeScopeSample, n)
		for grant, family := range order {
			wave[family] = rangeScopeSample{
				family: strconv.Itoa(family), arrival: uint64(family + 1), grant: uint64(n + grant + 1),
			}
		}
		for grant, family := range order {
			// Prior grants by later arrivals are exactly the observed overtakers.
			want := 0
			for _, prior := range order[:grant] {
				if prior > family {
					want++
				}
			}
			if rangeScopeOvertakes(wave, wave[family]) != want {
				return false
			}
		}
		return true
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 256, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}

func reportProviderRangeScopes(b *testing.B, arm *providerTailArm, name string, ranges, parallel int) {
	b.Helper()
	byFamily := readRangeScopes(b, arm.fixture)
	if len(byFamily) != len(arm.streams) {
		b.Fatalf("%s phase traces: got %d want %d", name, len(byFamily), len(arm.streams))
	}
	waves := make(map[string][]rangeScopeSample)
	waitByWave := make(map[string][]time.Duration)
	for _, stream := range arm.streams {
		i := strings.LastIndexByte(stream.family, '-')
		if i < 0 {
			b.Fatalf("missing benchmark wave for %s", stream.family)
		}
		wave := stream.family[:i]
		trace := byFamily[stream.family]
		counts := map[string]int{}
		var wait time.Duration
		for _, scope := range trace {
			counts[scope.phase]++
			if scope.phase != "other" {
				wait += scope.wait
			}
		}
		if counts["prepare"] != ranges || counts["queue"] != ranges || counts["other"] != 5 {
			b.Fatalf("%s unexpected range scope counts for %s: %v", name, stream.family, counts)
		}
		waves[wave] = append(waves[wave], trace...)
		waitByWave[wave] = append(waitByWave[wave], wait)
	}
	var spread []time.Duration
	for wave, waits := range waitByWave {
		if len(waits) != parallel {
			b.Fatalf("%s incomplete wave %s", name, wave)
		}
		spread = append(spread, slices.Max(waits)-slices.Min(waits))
	}
	b.ReportMetric(tailMillis(spread, 95), name+"-flow-wait-spread-p95-ms")
	p99 := arm.streams[tailRank(len(arm.streams), 99)].family
	for _, phase := range []string{"prepare", "queue"} {
		var waits, holds []time.Duration
		var atP99Wait, atP99Hold time.Duration
		var overtaken, maxOvertakes int
		for _, wave := range waves {
			for _, scope := range wave {
				if scope.phase != phase {
					continue
				}
				waits, holds = append(waits, scope.wait), append(holds, scope.hold)
				if scope.family == p99 {
					atP99Wait += scope.wait
					atP99Hold += scope.hold
				}
				if n := rangeScopeOvertakes(wave, scope); n > 0 {
					overtaken++
					maxOvertakes = max(maxOvertakes, n)
				}
			}
		}
		label := name + "-" + phase
		b.ReportMetric(tailMillis(waits, 99), label+"-wait-p99-ms")
		b.ReportMetric(tailMillis(holds, 99), label+"-hold-p99-ms")
		b.ReportMetric(millis(atP99Wait), label+"-wait-at-stream-p99-ms")
		b.ReportMetric(millis(atP99Hold), label+"-hold-at-stream-p99-ms")
		b.ReportMetric(100*float64(overtaken)/float64(len(waits)), label+"-overtaken-pct")
		b.ReportMetric(float64(maxOvertakes), label+"-max-overtakes")
	}
}
