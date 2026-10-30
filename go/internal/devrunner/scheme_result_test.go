package devrunner

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSchemePackageResultRejectsFalseZeroExit(t *testing.T) {
	complete := strings.Repeat("CASE-OK case\n", 19) + "HARNESS-OK (t)\nOK\n"
	for _, tc := range []struct {
		name, output string
		ok           bool
	}{
		{"complete", complete, true},
		{"empty", "", false},
		{"marker only", "OK\n", false},
		{"harness only", "HARNESS-OK (t)\nOK\n", false},
		{"partial", strings.Repeat("CASE-OK case\n", 18) + "HARNESS-OK (t)\nOK\n", false},
		{"missing terminal result", strings.TrimSuffix(complete, "OK\n"), false},
		{"failure despite marker", "HARNESS-ERROR (t)\n" + complete, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "result")
			if err := os.WriteFile(path, []byte(tc.output), 0600); err != nil {
				t.Fatal(err)
			}
			if err := validateSchemeResult(path); (err == nil) != tc.ok {
				t.Fatal("incorrect SDK result admission", err)
			}
		})
	}
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
