// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"strings"
	"testing"
	"testing/quick"
)

func headerEvidence(t *testing.T) string {
	t.Helper()
	var out strings.Builder
	fmt.Fprintf(&out, "weaver-header-seal-image sha256=%s profile=release\n", strings.Repeat("a", 64))
	for i := 0; i < 24; i++ {
		timing := &TransactionTimings{ProviderRequest: TimingSample{1, 10}, ProviderQueue: TimingSample{3, 5}, Commit: TimingSample{1, 5}, TransactionHold: TimingSample{1, 20}}
		row := HeaderSealSample{Block: i / 4, Slot: i % 4, Delayed: i%4 == 1 || i%4 == 2, Optimized: true, CPUs: 12, Wall: 100, Held: 4, Events: 3, Calls: i + 1, Timings: timing}
		data, err := json.Marshal(row)
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(&out, "weaver-header-seal %s\n", data)
	}
	return out.String()
}
func TestHeaderSealEvidenceRejectsIncompleteAndCorruptPairs(t *testing.T) {
	valid := headerEvidence(t)
	logged := strings.ReplaceAll(valid, "weaver-header-seal", "fixture_test.go:12: weaver-header-seal")
	if _, err := ReadHeaderSealEvidence(strings.NewReader(logged), 12); err != nil {
		t.Fatal("Go log prefix", err)
	}
	evidence, err := ReadHeaderSealEvidence(strings.NewReader(valid), 12)
	if err != nil || len(evidence.Samples) != 24 {
		t.Fatal(err)
	}
	check := func(selector uint8) bool {
		lines := strings.Split(strings.TrimSpace(valid), "\n")
		index := 1 + int(selector)%24
		switch selector % 7 {
		case 0:
			lines = append(lines[:index], lines[index+1:]...)
		case 1:
			lines[index] = lines[index%24+1]
		case 2:
			lines[index] = strings.Replace(lines[index], `"nanos":10`, `"absent":10`, 1)
		case 3:
			lines[index] = strings.Replace(lines[index], `"held":4`, `"held":0`, 1)
		case 4:
			lines[index] = strings.Replace(lines[index], `"cpus":12`, `"cpus":1`, 1)
		case 5:
			lines[0] = strings.Replace(lines[0], "release", "dev", 1)
		case 6:
			lines[0] = ""
		}
		_, err := ReadHeaderSealEvidence(strings.NewReader(strings.Join(lines, "\n")), 12)
		return err != nil
	}
	if err := quick.Check(check, &quick.Config{MaxCount: 64, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}
