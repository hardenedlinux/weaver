// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func schemeTranscript(cases int) string {
	var output strings.Builder
	output.WriteString("HARNESS (\"t/library-test.ss\")\nMODULE t/library-test.ss\nSUITE qualification\n")
	for index := range cases {
		fmt.Fprintf(&output, "CASE case %d\nCASE-OK case %d\n", index, index)
	}
	output.WriteString("SUITE-OK qualification\nMODULE-OK t/library-test.ss\nHARNESS-OK (\"t/library-test.ss\")\nOK\n")
	return output.String()
}

func schemeResultRoot(t testing.TB) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "t"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "t/library-test.ss"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestSchemePackageResultRejectsFalseZeroExit(t *testing.T) {
	root := schemeResultRoot(t)
	complete := schemeTranscript(40)
	for _, tc := range []struct {
		name, output string
		ok           bool
	}{
		{"complete", complete, true},
		{"original suite size", schemeTranscript(19), true},
		{"expanded suite", schemeTranscript(64), true},
		{"empty", "", false},
		{"marker only", "OK\n", false},
		{"harness only", "HARNESS-OK (\"t/library-test.ss\")\nOK\n", false},
		{"old count without protocol", strings.Repeat("CASE-OK case\n", 19) + "HARNESS-OK (t)\nOK\n", false},
		{"partial", strings.Replace(complete, "CASE-OK case 0\n", "", 1), false},
		{"no start", strings.Replace(complete, "CASE case 0\n", "", 1), false},
		{"wrong case", strings.Replace(complete, "CASE-OK case 0", "CASE-OK another", 1), false},
		{"wrong suite", strings.Replace(complete, "SUITE-OK qualification", "SUITE-OK another", 1), false},
		{"empty module", schemeTranscript(0), false},
		{"incomplete module", strings.Replace(complete, "MODULE-OK t/library-test.ss\n", "", 1), false},
		{"wrong module inventory", strings.ReplaceAll(complete, "library-test.ss", "another-test.ss"), false},
		{"different harness completion", strings.Replace(complete, "HARNESS-OK (\"t/library-test.ss\")", "HARNESS-OK ()", 1), false},
		{"duplicate module", strings.Replace(complete, "HARNESS-OK", "MODULE t/library-test.ss\nHARNESS-OK", 1), false},
		{"duplicate harness", "HARNESS (\"t/library-test.ss\")\n" + complete, false},
		{"missing terminal result", strings.TrimSuffix(complete, "OK\n"), false},
		{"failure despite marker", "HARNESS-ERROR (t)\n" + complete, false},
		{"error despite completion", complete + "*** ERROR unexpected\nOK\n", false},
		{"module failure despite completion", complete + "MODULE-FAIL t/library-test.ss\nOK\n", false},
		{"harness failure despite completion", complete + "HARNESS-FAIL (t)\nOK\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "result")
			if err := os.WriteFile(path, []byte(tc.output), 0600); err != nil {
				t.Fatal(err)
			}
			if err := validateSchemeResult(root, "t", path); (err == nil) != tc.ok {
				t.Fatal("incorrect SDK result admission", err)
			}
		})
	}
}

func TestSchemePackageResultZeroExitCannotReplaceProtocol(t *testing.T) {
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	root := schemeResultRoot(t)
	for _, valid := range []bool{false, true} {
		body := schemeTranscript(40)
		if !valid {
			body = strings.Repeat("CASE-OK case\n", 19) + "HARNESS-OK (t)\nOK\n"
		}
		stage := Stage{Name: "scheme-unit-tests", Binary: binary, Args: []string{"-test.run=^TestToolProcess$", "--", body}}
		result := runStage(context.Background(), root, t.TempDir(), Environment(map[string]string{"WEAVER_TEST_TOOL": "success"}), stage)
		if result.ExitCode == nil || *result.ExitCode != 0 || (result.Status == "PASS") != valid {
			t.Fatal("zero process exit replaced qualification evidence", valid, result)
		}
	}
}

func TestSchemeTestInventoryCannotOmitSourceOrAcceptAliases(t *testing.T) {
	root := schemeResultRoot(t)
	path := filepath.Join(t.TempDir(), "result")
	if err := os.WriteFile(path, []byte(schemeTranscript(40)), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "t/new-test.ss"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := validateSchemeResult(root, "t", path); err == nil {
		t.Fatal("a newly selected module was omitted")
	}
	if err := os.Remove(filepath.Join(root, "t/new-test.ss")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path, filepath.Join(root, "t/alias-test.ss")); err != nil {
		t.Fatal(err)
	}
	if _, err := schemeTestModules(root, "t"); err == nil {
		t.Fatal("aliased source entered the qualification inventory")
	}
}

// An optional actual SDK transcript checks format correspondence only. The
// stage owner, not this file-only check, qualifies process exit and timing.
func TestSchemePackageResultRecordedSDKProtocol(t *testing.T) {
	path := os.Getenv("WEAVER_SCHEME_RESULT_TRANSCRIPT")
	if path == "" {
		t.Skip("explicit standard-entry transcript required")
	}
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	if err := validateSchemeResult(root, "t", path); err != nil {
		t.Fatal(err)
	}
}

// Go owns generation, corpus replay and shrinking; incomplete transcripts must
// never qualify merely by matching a historical count or returning zero.
func FuzzSchemePackageResultProtocol(f *testing.F) {
	for _, count := range []uint8{1, 19, 40, 64} {
		for mode := range uint8(8) {
			f.Add(count, mode)
		}
	}
	f.Fuzz(func(t *testing.T, count, mutation uint8) {
		root := schemeResultRoot(t)
		body := schemeTranscript(1 + (int(count)+63)%64)
		mode := mutation % 8
		switch mode {
		case 1:
			body = strings.Replace(body, "CASE-OK case 0\n", "", 1)
		case 2:
			body = strings.Replace(body, "CASE case 0\n", "", 1)
		case 3:
			body = strings.Replace(body, "MODULE-OK t/library-test.ss\n", "", 1)
		case 4:
			body = strings.Replace(body, "SUITE-OK qualification\n", "", 1)
		case 5:
			body = strings.ReplaceAll(body, "library-test.ss", "other-test.ss")
		case 6:
			body = strings.Replace(body, "CASE-OK case 0", "CASE-OK mismatch", 1)
		case 7:
			body = strings.TrimSuffix(body, "OK\n")
		}
		path := filepath.Join(t.TempDir(), "result")
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
		if err := validateSchemeResult(root, "t", path); (err == nil) != (mode == 0) {
			t.Fatal("protocol completeness was not preserved", mode, err)
		}
	})
}

func TestSchemeUsesPackageTestEntry(t *testing.T) {
	t.Setenv("WEAVER_SCHEME_TOOL", "/selected/gerbil")
	stages, err := Stages("check-scheme", "go")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, stage := range stages {
		if stage.Name == "scheme-dynamic-images" {
			t.Fatal("diagnostic inventory is still a package test prerequisite")
		}
		if stage.Name == "scheme-unit-tests" {
			found = true
			if stage.Binary != "/selected/gerbil" || strings.Join(stage.Args, " ") != "test -g -v 5 t" {
				t.Fatal("not using official package test entry", stage)
			}
		}
	}
	if !found {
		t.Fatal("Scheme package tests missing")
	}
}

func TestSchemePackageResultIntegrationCannotBorrowUnitReceipt(t *testing.T) {
	for _, entry := range []struct{ stage, directory string }{
		{"scheme-source-integration-tests", "t/integration"},
		{"scheme-module-selection-integration", "t/qualification/module-selection"},
	} {
		t.Run(entry.stage, func(t *testing.T) {
			root := schemeResultRoot(t)
			directory := filepath.Join(root, entry.directory)
			if err := os.MkdirAll(directory, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(directory, "library-test.ss"), nil, 0600); err != nil {
				t.Fatal(err)
			}
			binary, err := os.Executable()
			if err != nil {
				t.Fatal(err)
			}
			for _, valid := range []bool{false, true} {
				body := schemeTranscript(20)
				if valid {
					body = strings.ReplaceAll(body, "t/library-test.ss", entry.directory+"/library-test.ss")
				}
				result := runStage(context.Background(), root, t.TempDir(),
					Environment(map[string]string{"WEAVER_TEST_TOOL": "success"}),
					Stage{Name: entry.stage, Binary: binary, Args: []string{"-test.run=^TestToolProcess$", "--", body}})
				if result.ExitCode == nil || *result.ExitCode != 0 || (result.Status == "PASS") != valid {
					t.Fatal("integration accepted a different module inventory", valid, result)
				}
			}
		})
	}
}
