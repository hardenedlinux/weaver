// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func liveVerificationInputs(t testing.TB) (string, map[string]string) {
	t.Helper()
	working, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(working)
	if err != nil {
		t.Fatal(err)
	}
	inputs, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	return root, inputs
}

func verificationInputsFixture(t testing.TB) (string, map[string]string) {
	t.Helper()
	root, inputs := liveVerificationInputs(t)
	return copyVerificationInputs(t, root, inputs), inputs
}

// Derive requirements from the actual executable plan, not a duplicate list of
// expected model filenames. In particular, this catches newly added gate roots.
func TestVerificationPlanProofInputsAreBound(t *testing.T) {
	root, inputs := liveVerificationInputs(t)
	for _, stage := range Plan("go") {
		for _, arg := range stage.Args {
			if !strings.HasPrefix(arg, "dev/proofs/") || (filepath.Ext(arg) != ".lean" && filepath.Ext(arg) != ".qnt") {
				continue
			}
			if _, err := os.Stat(filepath.Join(root, arg)); err != nil {
				t.Fatalf("gate %s has an unavailable proof input %s: %v", stage.Name, arg, err)
			}
			if inputs[arg] == "" {
				t.Fatalf("gate %s runs an unbound proof input %s", stage.Name, arg)
			}
		}
	}
}

func TestProofAndArchitectureChangesInvalidateCurrentness(t *testing.T) {
	root, before := verificationInputsFixture(t)
	for _, path := range []string{"dev/proofs/quint/InventoryProbe.qnt", "dev/proofs/lean/InventoryProbe.lean", "docs/inventory-probe.org", "docs/inventory-probe.d2"} {
		t.Run(path, func(t *testing.T) {
			full := filepath.Join(root, path)
			if err := os.WriteFile(full, []byte("source revision one\n"), 0600); err != nil {
				t.Fatal(err)
			}
			first, err := SourceInputs(root)
			if err != nil || first[path] == "" || sourceCurrentness(root, t.TempDir(), before).Status != "FAIL" {
				t.Fatal("new source escaped currentness", path, err)
			}
			if err := os.WriteFile(full, []byte("source revision two\n"), 0600); err != nil {
				t.Fatal(err)
			}
			second, err := SourceInputs(root)
			if err != nil || second[path] == first[path] || sourceCurrentness(root, t.TempDir(), first).Status != "FAIL" {
				t.Fatal("source edit escaped currentness", path, err)
			}
			if err := os.Remove(full); err != nil {
				t.Fatal(err)
			}
			if sourceCurrentness(root, t.TempDir(), second).Status != "FAIL" {
				t.Fatal("source deletion escaped currentness", path)
			}
		})
	}
	if after, err := SourceInputs(root); err != nil || !maps.Equal(before, after) {
		t.Fatal("fixture restoration changed the source inventory", err)
	}
}

func TestSourceInventoryExcludesGeneratedAndArchivedArtifacts(t *testing.T) {
	root, before := verificationInputsFixture(t)
	for _, path := range []string{"dev/proofs/cedar/.lake/packages/generated/BuildOutput.lean", "docs/generated.svg", "dev/proofs/evidence/inventory/receipt.json"} {
		full := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(full), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte("generated or historical output"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if after, err := SourceInputs(root); err != nil || !maps.Equal(before, after) {
		t.Fatal("generated or historical artifacts became project source", err)
	}
}

func TestSourceInventoryRejectsProofAliases(t *testing.T) {
	for _, directory := range []bool{false, true} {
		root, _ := verificationInputsFixture(t)
		external := t.TempDir()
		file := filepath.Join(external, "external.qnt")
		if err := os.WriteFile(file, []byte("external source"), 0600); err != nil {
			t.Fatal(err)
		}
		alias := filepath.Join(root, "dev/proofs/quint/Alias")
		if !directory {
			external = file
			alias += ".qnt"
		}
		if err := os.Symlink(external, alias); err != nil {
			t.Fatal(err)
		}
		if _, err := SourceInputs(root); err == nil {
			t.Fatal("external proof alias admitted", directory)
		}
	}
}
