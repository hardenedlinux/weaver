// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Stage observations account for polled failures as well as successes. They are
// diagnostics only: zero bytes or a missing stage never release a reservation.
func providerTransportPhases(b testing.TB, f *fixture) map[string][4]time.Duration {
	b.Helper()
	raw, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		b.Fatal(err)
	}
	result := map[string][4]time.Duration{}
	for _, line := range strings.Split(string(raw), "\n") {
		tail, ok := strings.CutPrefix(line, "weaver-provider-transport ")
		if !ok {
			continue
		}
		fields := strings.Fields(tail)
		if len(fields) != 5 {
			b.Fatalf("invalid transport observation: %q", line)
		}
		if _, duplicate := result[fields[0]]; duplicate {
			b.Fatalf("duplicate transport observation: %q", line)
		}
		var phases [4]time.Duration
		for i, field := range fields[1:] {
			parts := strings.Split(field, ":")
			if len(parts) != 3 || parts[1] != "1" || parts[2] != "1" {
				b.Fatalf("unfinished transport in successful cohort: %q", line)
			}
			n, err := strconv.ParseInt(parts[0], 10, 64)
			if err != nil || n < 0 {
				b.Fatalf("invalid stage: %q", field)
			}
			phases[i] = time.Duration(n)
		}
		result[fields[0]] = phases
	}
	return result
}
func reportProviderTransport(b *testing.B, arm *providerTailArm, label string) {
	b.Helper()
	phases := providerTransportPhases(b, arm.fixture)
	var samples [4][]time.Duration
	for _, stream := range arm.streams {
		row, ok := phases[stream.family]
		if !ok {
			b.Fatalf("missing transport for %s", stream.family)
		}
		for i, n := range row {
			samples[i] = append(samples[i], n)
		}
	}
	for i, name := range []string{"tcp", "tls", "request-seal", "response-headers"} {
		b.ReportMetric(tailMillis(samples[i], 99), fmt.Sprintf("%s-%s-p99-ms/invoke", label, name))
	}
}
