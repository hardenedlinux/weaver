// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPipelineBenchmarkRequiresBothPathsAndEveryStage(t *testing.T) {
	var log strings.Builder
	for _, name := range []string{"inline", "assets"} {
		for range 3 {
			fmt.Fprintf(&log, "BenchmarkGatewayCompiledPipeline/%s-12 1 1000 ns/op 800 activation-ns/op 190 send-ns/op 100 B/op 2 allocs/op\n", name)
		}
	}
	valid := log.String()
	for _, tc := range []struct {
		name, text string
		ok         bool
	}{
		{"complete", valid, true},
		{"missing sample", strings.SplitN(valid, "\n", 2)[1], false},
		{"missing phase", strings.Replace(valid, "800 activation-ns/op ", "", 1), false},
		{"wrong CPU", strings.Replace(valid, "-12 ", "-1 ", 1), false},
		{"replay calibration", strings.Replace(valid, "-12 1 ", "-12 20 ", 1), false},
		{"bad total", strings.Replace(valid, "1000 ns/op", "100 ns/op", 1), false},
		{"duplicate phase", strings.Replace(valid, "send-ns/op", "activation-ns/op", 1), false},
		{"nonfinite", strings.Replace(valid, "800 activation", "NaN activation", 1), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "bench.log")
			if err := os.WriteFile(path, []byte(tc.text), 0600); err != nil {
				t.Fatal(err)
			}
			rows, err := readPipelineBenchmarks(path, 12)
			if (err == nil) != tc.ok {
				t.Fatal("measurement admission", err)
			}
			if tc.ok && len(rows) != 6 {
				t.Fatal("lost pipeline sample")
			}
		})
	}
}
func TestRuntimeBenchmarkUsesSchemeCedarExecutionPipeline(t *testing.T) {
	stages, err := Stages("bench-runtime", "go")
	if err != nil {
		t.Fatal(err)
	}
	if len(stages) != 6 || stages[0].Name != "scheme-policy-library" || stages[1].Name != "scheme-policy-pkg-config" || stages[5].Name != "runtime-pipeline-benchmark" {
		t.Fatal("runtime benchmark preparation/order", stages)
	}
	args := strings.Join(stages[5].Args, " ")
	for _, required := range []string{"-tags=integration,schemeintegration", "^BenchmarkGatewayCompiledPipeline$", "-benchtime=1x", "-count=3"} {
		if !strings.Contains(args, required) {
			t.Fatal("runtime workload changed", required)
		}
	}
}

func TestSourceAdmissionBenchmarksRetainEverySizeAndRepetition(t *testing.T) {
	var output strings.Builder
	for _, name := range sourceAdmissionBenchmarks {
		for range 3 {
			fmt.Fprintf(&output, "%s-12 10 1000 ns/op 100 B/op 2 allocs/op\n", name)
		}
	}
	path := filepath.Join(t.TempDir(), "admission.log")
	if err := os.WriteFile(path, []byte(output.String()), 0600); err != nil {
		t.Fatal(err)
	}
	rows, err := readGoBenchmarks(path, 12, sourceAdmissionBenchmarks...)
	if err != nil || len(rows) != 18 {
		t.Fatal("local admission measurements lost", err)
	}
	if err := os.WriteFile(path, []byte(strings.SplitN(output.String(), "\n", 2)[1]), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readGoBenchmarks(path, 12, sourceAdmissionBenchmarks...); err == nil {
		t.Fatal("missing local admission sample accepted")
	}
}

func TestPublishedPipelineKeepsSchemeOutsideExecutionQualification(t *testing.T) {
	stages, err := Stages("bench-execution", "go")
	if err != nil {
		t.Fatal("execution qualification", err)
	}
	// Name every required responsibility. Added paired workloads cannot be
	// mistaken for a failure merely because an old total stopped matching.
	required := map[string]bool{
		"execution-benchmark-target": true, "execution-policy-tests": true,
		"execution-backend-tests": true, "execution-policy-benchmark": true,
		"execution-ledger-benchmark": true, "execution-provider-benchmark": true,
		"execution-delivery-join-pair": true, "execution-encoding-benchmark": true, "execution-range-prepare-pair": true,
		"execution-scheduled-encoding-pair": true, "execution-contention-pair": true,
		"execution-provider-integration": true, "published-pipeline-benchmark": true,
		"execution-header-seal-pair": true, "execution-header-wait-pair": true,
		"execution-streaming-pair": true,
	}
	for _, stage := range stages {
		if !required[stage.Name] {
			t.Fatal("unexpected or duplicate execution stage", stage.Name)
		}
		delete(required, stage.Name)
	}
	if len(required) != 0 {
		t.Fatal("missing execution responsibilities", required)
	}
	for _, stage := range stages {
		if strings.Contains(strings.Join(stage.Args, " "), "schemeintegration") || strings.Contains(stage.Name, "scheme") {
			t.Fatal("execution boundary depends on Scheme", stage)
		}
	}
	var output strings.Builder
	for range 3 {
		fmt.Fprintln(&output, "BenchmarkGatewayPublishedPipeline/registered-12 1 1000 ns/op 800 activation-ns/op 190 send-ns/op 100 B/op 2 allocs/op")
	}
	path := filepath.Join(t.TempDir(), "published.log")
	if err := os.WriteFile(path, []byte(output.String()), 0600); err != nil {
		t.Fatal(err)
	}
	rows, err := readPipelineBenchmarks(path, 12, "BenchmarkGatewayPublishedPipeline/registered")
	if err != nil || len(rows) != 3 {
		t.Fatal("published measurements lost", err)
	}
}

func TestStreamingPairRequiresCompleteOrderedBlocks(t *testing.T) {
	var lines []string
	for i := 0; i < 24; i++ {
		arm := "single"
		if i%4 == 1 || i%4 == 2 {
			arm = "batch"
		}
		lines = append(lines, fmt.Sprintf("BenchmarkGatewayStreamingPair/%02d-%s-12 1 1000 ns/op 800 activation-ns/op 190 send-ns/op 100 B/op 2 allocs/op", i, arm))
	}
	for _, kind := range []string{"complete", "missing", "repeated", "reordered", "wrong CPU", "missing image", "debug image", "multiple images"} {
		t.Run(kind, func(t *testing.T) {
			input := append([]string(nil), lines...)
			switch kind {
			case "missing":
				input = input[1:]
			case "repeated":
				input[1] = input[0]
			case "reordered":
				input[0], input[1] = input[1], input[0]
			case "wrong CPU":
				input[0] = strings.Replace(input[0], "-12 1", "-1 1", 1)
			}
			header := "test-owned provider image sha256=" + strings.Repeat("a", 64) + " profile=release\n"
			switch kind {
			case "missing image":
				header = ""
			case "debug image":
				header = strings.Replace(header, "release", "dev", 1)
			case "multiple images":
				header += header
			}
			path := filepath.Join(t.TempDir(), "pair.log")
			if err := os.WriteFile(path, []byte(header+strings.Join(input, "\n")), 0600); err != nil {
				t.Fatal(err)
			}
			headerPath := filepath.Join(t.TempDir(), "header-pair.log")
			headerInput := strings.NewReplacer("BenchmarkGatewayStreamingPair", "BenchmarkGatewayHeaderWaitPair", "-single-", "-immediate-", "-batch-", "-delayed-").Replace(header + strings.Join(input, "\n"))
			if err := os.WriteFile(headerPath, []byte(headerInput), 0600); err != nil {
				t.Fatal(err)
			}
			headerRows, headerErr := readProviderPairBenchmarks(headerPath, 12, "BenchmarkGatewayHeaderWaitPair", "immediate", "delayed")
			if (headerErr == nil) != (kind == "complete") || (headerErr == nil && len(headerRows) != 24) {
				t.Fatal("header pair admission", headerErr)
			}
			rows, err := readStreamingPairBenchmarks(path, 12)

			if (err == nil) != (kind == "complete") {
				t.Fatal("pair admission", err)
			}
			if err == nil && len(rows) != 24 {
				t.Fatal("lost pair samples")
			}
		})
	}
}
