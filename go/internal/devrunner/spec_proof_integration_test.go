// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build proofintegration

package devrunner

import (
	"context"
	"encoding/json"
	"maps"
	"os"
	"path/filepath"
	"strconv"
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

func TestSPECProofClosureResearchModels(t *testing.T) {
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	base := filepath.Join(root, ".cache", "spec-qualification")
	if err = os.MkdirAll(base, 0700); err != nil {
		t.Fatal(err)
	}
	directory, err := os.MkdirTemp(base, "model-closure-")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()
	before, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	build := runStage(ctx, root, directory, os.Environ(), Stage{Name: "model-closure-source-build", Binary: "elan", Args: []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "build", "ModelClosure"}})
	if build.Status != "PASS" {
		t.Fatalf("model source closure build failed: %+v", build)
	}
	stage := Stage{Name: "model-closure-positive-audit", Binary: "elan", Args: []string{"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "env", "lean", "--json", "dev/proofs/cedar/ModelClosure.lean"}}
	result := runStage(ctx, root, directory, os.Environ(), stage)
	if result.Status != "PASS" || result.ExitCode == nil || *result.ExitCode != 0 || result.Lean == nil {
		t.Fatalf("complete model closure must pass the strict positive audit: %+v", result)
	}
	modules := map[string]bool{}
	moduleReports, proofReports, reportedProofs := 0, 0, 0
	for _, diagnostic := range result.Lean.Diagnostics {
		if data, found := strings.CutPrefix(diagnostic.Data, "WEAVER_MODEL_MODULES "); found {
			moduleReports++
			var names []string
			if err = json.Unmarshal([]byte(data), &names); err != nil {
				t.Fatal(err)
			}
			for _, name := range names {
				modules[name] = true
			}
		}
		if data, found := strings.CutPrefix(diagnostic.Data, "WEAVER_MODEL_THEOREMS "); found {
			proofReports++
			reportedProofs, err = strconv.Atoi(strings.TrimSpace(data))
			if err != nil {
				t.Fatal(err)
			}
		}
	}
	if moduleReports != 1 || proofReports != 1 || reportedProofs == 0 || reportedProofs != len(result.Lean.Declarations) {
		t.Fatal("incomplete reflected model theorem inventory", moduleReports, proofReports, reportedProofs, len(result.Lean.Declarations))
	}
	expected := map[string]bool{}
	for _, source := range []string{"dev/specs/lean", "dev/proofs/lean"} {
		entries, err := os.ReadDir(filepath.Join(root, source))
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if entry.IsDir() {
				t.Fatal("model source layout requires explicit module coverage", source, entry.Name())
			}
			if !strings.HasSuffix(entry.Name(), ".lean") {
				continue
			}
			name := strings.TrimSuffix(entry.Name(), ".lean")
			if expected[name] {
				t.Fatal("ambiguous model module", name)
			}
			expected[name] = true
			if !modules[name] {
				t.Fatal("model source absent from actual Lean import closure", source, name)
			}
		}
	}
	required := map[string]bool{
		"Weaver.FiniteDomainMigration.finite_budget_bound":                                 false,
		"Weaver.FiniteDomainMigration.migration_preserves_obligations":                     false,
		"Weaver.GambitLocatorClosure.semantic_owner_and_gambit_source_compose":             false,
		"Weaver.DynamicImportBoundary.dynamic_import_pass_still_closes_handles":            false,
		"Weaver.DynamicLoaderPublication.loader_completion_still_needs_cleanup":            false,
		"Weaver.LlmSubjectAuthority.original_reservation_once":                             false,
		"Weaver.DomainMigrationComposition.gateway_final_use_preserves_domain_contract":    false,
		"Weaver.DomainMigrationComposition.overbooked_actual_view_cannot_supply_final_run": false,
		"Weaver.DomainMigrationComposition.head_cas_preserves_original_obligations":        false,
		"Weaver.DomainMigrationComposition.final_use_on_committed_union":                   false,
	}
	for _, declaration := range result.Lean.Declarations {
		if _, exists := required[declaration.Name]; exists {
			required[declaration.Name] = true
		}
	}
	for name, found := range required {
		if !found {
			t.Fatal("required positive proof missing", name)
		}
	}
	inputs, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	if !maps.Equal(before, inputs) {
		t.Fatal("model sources changed during acceptance")
	}
	if err = writeReceipt(directory, Receipt{Root: root, Status: result.Status, Mode: "model-closure-positive-audit", Inputs: inputs, Stages: []Result{build, result}}); err != nil {
		t.Fatal(err)
	}
	t.Logf("PASS modules=%d theorems=%d evidence=%s", len(expected), reportedProofs, directory)
}
