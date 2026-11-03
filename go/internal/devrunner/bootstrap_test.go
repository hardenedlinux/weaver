// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestBootstrapPreservesLockedDependencyAndCompilerIdentity(t *testing.T) {
	working, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(working)
	if err != nil {
		t.Fatal(err)
	}
	pin, err := os.ReadFile(filepath.Join(root, "dev/proofs/cedar/lean-toolchain"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(pin)) != proofToolchain {
		t.Fatal("native and imported proof toolchains diverge")
	}
	stages, err := Stages("bootstrap", "configured-go")
	if err != nil {
		t.Fatal(err)
	}
	if len(stages) != 4 || stages[0].Binary != "cargo" || !slices.Contains(stages[0].Args, "--locked") {
		t.Fatal("bootstrap lost its locked Cargo boundary")
	}
	if stages[1].Binary != "configured-go" || strings.Join(stages[1].Args, " ") != "-C go mod download" {
		t.Fatal("Go dependency preparation must use the actual configured compiler and existing module")
	}
	for _, stage := range stages {
		for _, arg := range stage.Args {
			if slices.Contains([]string{"update", "upgrade", "tidy", "latest"}, arg) {
				t.Fatalf("dependency resolution drift in %s: %s", stage.Name, arg)
			}
		}
		if stage.Binary == "elan" && !slices.Contains(stage.Args, proofToolchain) {
			t.Fatal("proof preparation lost its existing toolchain identity")
		}
	}
}
