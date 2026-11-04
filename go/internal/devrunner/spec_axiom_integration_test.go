// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

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

// This is a refusal control, never acceptance of the imported semantic theorem.
// Keep the real failed audit and its exact unapproved dependencies in cache.
func TestImportedSPECCompositionCannotBypassAxiomGate(t *testing.T) {
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	base := filepath.Join(root, ".cache", "spec-qualification")
	if err = os.MkdirAll(base, 0700); err != nil {
		t.Fatal(err)
	}
	directory, err := os.MkdirTemp(base, "axiom-refusal-")
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
	if result.Status != "FAIL" || result.ExitCode == nil || *result.ExitCode != 0 || result.Lean == nil || !strings.Contains(result.Error, "unapproved Lean axiom:") {
		t.Fatalf("expected actual zero-exit SPEC axiom refusal, not process failure or proof admission: %+v", result)
	}
	structural, native := 0, 0
	for _, declaration := range result.Lean.Declarations {
		if strings.HasPrefix(declaration.Name, "Weaver.QualifiedReview.changed_") && len(declaration.Axioms) == 0 {
			structural++
		}
		if declaration.Name == "Weaver.QualifiedReview.qualified_execution_and_recovery_preserve_original" {
			for _, axiom := range declaration.Axioms {
				if strings.Contains(axiom, ".native_decide.") {
					native++
				}
			}
		}
	}
	if structural != 2 || native == 0 {
		t.Fatal("missing actual structural/semantic audit separation", structural, native)
	}
	t.Logf("REFUSED imported semantic proof; structural=%d unapproved-native=%d audit=%s", structural, native, directory)
}
