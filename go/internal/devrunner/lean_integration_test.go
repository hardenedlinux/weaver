// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build proofintegration

package devrunner

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestLeanJSONCompilerAndRunner(t *testing.T) {
	for name, body := range map[string]string{
		"valid": "by rfl",
		"sorry": "by sorry",
		"error": "by exact False.elim",
	} {
		t.Run(name, func(t *testing.T) {
			root, _ := leanFixture(t)
			source := "namespace Example\ntheorem retained : 1 = 1 := " + body + "\n#print axioms retained\nend Example\n"
			if err := os.WriteFile(filepath.Join(root, "Proof.lean"), []byte(source), 0600); err != nil {
				t.Fatal(err)
			}
			stage := Stage{Name: "lean-fixture", Binary: "elan", Args: []string{"run", proofToolchain, "lean", "--json", "Proof.lean"}}
			result := runStage(context.Background(), root, root, os.Environ(), stage)
			if name == "valid" {
				if result.Status != "PASS" || result.Lean == nil || len(result.Lean.Declarations) != 1 {
					t.Fatalf("real Lean evidence failed: %+v", result)
				}
			} else if result.Status != "FAIL" {
				t.Fatalf("incomplete proof admitted: %+v", result)
			}
			if name == "sorry" && (result.ExitCode == nil || *result.ExitCode != 0) {
				t.Fatalf("negative control must expose Lean's zero-exit sorry case: %+v", result)
			}
		})
	}
}

func TestLeanJSONMaintainedProofStages(t *testing.T) {
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, stage := range Plan("go") {
		if leanSource(stage) == "" {
			continue
		}
		count++
		result := runStage(context.Background(), root, t.TempDir(), os.Environ(), stage)
		if result.Status != "PASS" || result.Lean == nil {
			t.Fatalf("maintained proof stage %s: %+v", stage.Name, result)
		}
	}
	if count != 9 {
		t.Fatalf("unexpected maintained Lean stage inventory: %d", count)
	}
}
