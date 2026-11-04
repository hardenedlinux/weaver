// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration

package devrunner

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestCargoBenchmarkTargetFollowsCargoConfiguration(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "Cargo.toml"), []byte("[package]\nname='benchmark-target-fixture'\nversion='0.1.0'\nedition='2024'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "src"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "src/lib.rs"), []byte("pub fn fixture() {}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	lock := exec.Command("cargo", "generate-lockfile", "--offline")
	lock.Dir = root
	if data, err := lock.CombinedOutput(); err != nil {
		t.Fatal("fixture Cargo lock", err, string(data))
	}
	configured := filepath.Join(t.TempDir(), "configured-target")
	for _, target := range []string{configured, "relative-target"} {
		actual, err := cargoBenchmarkTarget(t.Context(), root, Environment(map[string]string{"CARGO_TARGET_DIR": target}))
		expected := target
		if !filepath.IsAbs(expected) {
			expected = filepath.Join(root, target)
		}
		if err != nil || actual != expected {
			t.Fatal("Cargo target selection was guessed", actual, expected, err)
		}
	}
	if err := os.Mkdir(filepath.Join(root, ".cargo"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".cargo/config.toml"), []byte("[build]\ntarget-dir='workspace-output'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	// Remove the inherited override from this child only; Cargo configuration wins.
	actual, err := cargoBenchmarkTarget(t.Context(), root, slices.DeleteFunc(Environment(nil), func(entry string) bool { return strings.HasPrefix(entry, "CARGO_TARGET_DIR=") }))
	if err != nil || actual != filepath.Join(root, "workspace-output") {
		t.Fatal("Cargo config target ignored", actual, err)
	}
}
