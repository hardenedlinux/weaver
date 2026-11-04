// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build proofintegration

package devrunner

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSPECProofClosureComposition(t *testing.T) {
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	base := filepath.Join(root, ".cache", "spec-qualification")
	if err = os.MkdirAll(base, 0700); err != nil {
		t.Fatal(err)
	}
	directory, err := os.MkdirTemp(base, "proof-closure-")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()
	stage := Stage{Name: "spec-semantic-composition-audit", Binary: "elan", Args: []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "env", "lean", "--json", "dev/proofs/cedar/QualifiedReview.lean"}}
	result := runStage(ctx, root, directory, os.Environ(), stage)
	inputs, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	if err = writeReceipt(directory, Receipt{Root: root, Status: result.Status, Mode: "spec-semantic-composition-audit", Inputs: inputs, Stages: []Result{result}}); err != nil {
		t.Fatal(err)
	}
	if result.Status != "PASS" || result.ExitCode == nil || *result.ExitCode != 0 || result.Lean == nil {
		t.Fatalf("real SPEC composition must pass the unchanged strict axiom gate: %+v", result)
	}
	structural, semantic := 0, 0
	for _, declaration := range result.Lean.Declarations {
		if strings.HasPrefix(declaration.Name, "Weaver.QualifiedReview.changed_") && len(declaration.Axioms) == 0 {
			structural++
		}
		if declaration.Name == "Weaver.QualifiedReview.qualified_execution_and_recovery_preserve_original" {
			semantic++
			for _, axiom := range declaration.Axioms {
				if axiom != "propext" && axiom != "Classical.choice" && axiom != "Quot.sound" {
					t.Fatal("unapproved semantic dependency", axiom)
				}
			}
		}
	}
	if structural != 2 || semantic != 1 {
		t.Fatal("missing actual structural/semantic proof", structural, semantic)
	}
	t.Logf("PASS real SPEC composition; structural=%d semantic=%d audit=%s", structural, semantic, directory)
}

func TestSPECProofClosureRejectsFalseArithmetic(t *testing.T) {
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	base := filepath.Join(root, ".cache", "spec-qualification")
	if err = os.MkdirAll(base, 0700); err != nil {
		t.Fatal(err)
	}
	directory, err := os.MkdirTemp(base, "false-arithmetic-")
	if err != nil {
		t.Fatal(err)
	}
	source := "import SpecProofClosure\nopen Lean Elab Command Meta Term\nrun_cmd do\n  logInfo \"CHECKING_FALSE_ARITHMETIC\"\n  liftTermElabM do\n    let type ← elabType (← `(decide ((1 : Nat) = 2) = true))\n    let _ ← Weaver.SpecProofClosure.proveClosedArithmetic type\n    pure ()\n"
	path := filepath.Join(directory, "FalseArithmetic.lean")
	if err = os.WriteFile(path, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()
	result := runStage(ctx, root, directory, os.Environ(), Stage{Name: "false-arithmetic", Binary: "elan", Args: []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "env", "lean", "--json", path}})
	log, err := os.ReadFile(filepath.Join(directory, result.Log))
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != "FAIL" || result.ExitCode == nil || *result.ExitCode == 0 || !strings.Contains(string(log), "CHECKING_FALSE_ARITHMETIC") || !strings.Contains(string(log), "decide") {
		t.Fatalf("false arithmetic must fail in the actual kernel proof construction: %+v: %s", result, log)
	}
}
