// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

func TestSchemeObservationPreservesChunkedOutputAndExitBoundary(t *testing.T) {
	var log bytes.Buffer
	started := time.Now().Add(-time.Second)
	output := &schemeOutput{destination: &log, started: started}
	chunks := []string{"HAR", "NESS (t)\nCA", "SE original\nHARNESS-OK (t)\nO", "K\n"}
	for _, chunk := range chunks {
		if _, err := output.Write([]byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}
	if log.String() != strings.Join(chunks, "") {
		t.Fatal("timing observer changed the SDK output")
	}
	finished := output.terminal.Add(2 * time.Second)
	report := output.timing(finished)
	if report.PreHarness == "" || report.FirstCase == "" || report.HarnessDone == "" || report.Terminal == "" || report.AfterTerminal != "2s" {
		t.Fatalf("missing execution/exit boundary: %+v", report)
	}
	var absent bytes.Buffer
	unreturned := &schemeOutput{destination: &absent, started: started}
	if _, err := unreturned.Write([]byte("HARNESS (t)\nCASE original\n")); err != nil {
		t.Fatal(err)
	}
	if report := unreturned.timing(finished); report.Terminal != "" || report.AfterTerminal != "" {
		t.Fatal("fabricated a terminal marker or shutdown interval")
	}
}
