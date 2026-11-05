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

func TestSingleGoModuleRootNeedsNoWorkspace(t *testing.T) {
	root := t.TempDir()
	module := filepath.Join(root, "go")
	if err := os.MkdirAll(filepath.Join(module, "cmd"), 0700); err != nil {
		t.Fatal(err)
	}
	for path, data := range map[string]string{"Cargo.toml": "[workspace]\n", "go/go.mod": "module example.test/control\n"} {
		if err := os.WriteFile(filepath.Join(root, path), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	actual, err := FindRoot(filepath.Join(module, "cmd"))
	if err != nil || actual != root {
		t.Fatalf("single-module project root: %q %v", actual, err)
	}
}

func TestToolProcess(t *testing.T) {
	mode := os.Getenv("WEAVER_TEST_TOOL")
	if mode == "" {
		return
	}
	for i, arg := range os.Args {
		if arg == "--" {
			fmt.Fprintln(os.Stdout, strings.Join(os.Args[i+1:], "|"))
			break
		}
	}
	if mode == "failure" {
		fmt.Fprintln(os.Stderr, "retained negative-control failure")
		os.Exit(7)
	}
	os.Exit(0)
}
func TestStagePreservesFailureAndLiteralArguments(t *testing.T) {
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"success", "failure"} {
		directory := t.TempDir()
		literal := "$(touch should-not-exist); not a shell"
		stage := Stage{Name: mode, Binary: binary, Args: []string{"-test.run=^TestToolProcess$", "--", literal}}
		result := runStage(context.Background(), directory, directory, Environment(map[string]string{"WEAVER_TEST_TOOL": mode}), stage)
		resolved, err := filepath.EvalSymlinks(binary)
		if err != nil || result.ResolvedBinary != resolved {
			t.Fatalf("executable identity missing: %v: %+v", err, result)
		}
		expected := 0
		status := "PASS"
		if mode == "failure" {
			expected = 7
			status = "FAIL"
		}
		if result.Status != status || result.ExitCode == nil || *result.ExitCode != expected {
			t.Fatalf("bad process result: %+v", result)
		}
		data, err := os.ReadFile(filepath.Join(directory, result.Log))
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(data), literal) {
			t.Fatal("literal argument altered")
		}
		if mode == "failure" && !strings.Contains(string(data), "negative-control failure") {
			t.Fatal("failure evidence missing")
		}
		if _, err := os.Stat(filepath.Join(directory, "should-not-exist")); !os.IsNotExist(err) {
			t.Fatal("argument evaluated as shell")
		}
	}
}
