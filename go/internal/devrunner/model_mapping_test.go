// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSelectedArchitectureKeepsExactMappedScope(t *testing.T) {
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	inputs, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	isolated := copyVerificationInputs(t, root, inputs)
	const selected = "docs/50-59-research-program/59-provider-rpc/59.77-mrr-turso-storage.d2"
	if _, err := publishModelViewsWithEvidence(context.Background(), isolated, nil, selected); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(isolated, ".cache/d2/model-views.json"))
	if err != nil {
		t.Fatal(err)
	}
	var capture ModelViewCapture
	if err := json.Unmarshal(data, &capture); err != nil {
		t.Fatal(err)
	}
	if len(capture.Mapped) != 1 || capture.Mapped[selected] == "" {
		t.Fatal("selected mapping widened or lost its source")
	}
	for _, selection := range [][]string{{"../outside.d2"}, {selected, selected}, {"docs/missing.d2"}, {"docs/architecture/diagrams/00d-zero-trust-overview.d2"}} {
		if _, err := publishModelViewsWithEvidence(context.Background(), isolated, nil, selection...); err == nil {
			t.Fatalf("accepted incomplete or invalid scope: %v", selection)
		}
	}
}

func TestD2SemanticCopyCannotOverrideSDKProjection(t *testing.T) {
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	capture, err := CaptureModelViews(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	inputs, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	isolated := copyVerificationInputs(t, root, inputs)
	if err := mapModelDeclarations(isolated, capture); err == nil || !strings.Contains(err.Error(), "lacks current Lean environment") {
		t.Fatalf("missing Lean environment must block security projection: %v", err)
	}
	delete(capture.Descriptions, "WeaverViews::zeroTrust")
	if err := mapModelDeclarations(isolated, capture); err != nil {
		t.Fatal(err)
	}
	baseline := map[string]string{}
	for source, body := range capture.Mapped {
		baseline[source] = body
	}
	if len(baseline) != 6 {
		t.Fatalf("expected product and development projections, got %d", len(baseline))
	}
	for source, body := range baseline {
		forged := body
		match := mappedJSON.FindStringSubmatch(forged)
		var declaration mappedFigure
		if err := json.Unmarshal([]byte(match[1]), &declaration); err != nil {
			t.Fatal(err)
		}
		declaration.Title = "D2-authored replacement"
		for id := range declaration.ModelSource.Labels {
			declaration.ModelSource.Labels[id] = "D2-authored responsibility"
			break
		}
		encoded, err := json.MarshalIndent(declaration, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		forged = strings.Replace(forged, match[1], string(encoded), 1)
		if err := os.WriteFile(filepath.Join(isolated, source), []byte(forged), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := mapModelDeclarations(isolated, capture); err != nil {
		t.Fatal(err)
	}
	for source, want := range baseline {
		if capture.Mapped[source] != want {
			t.Fatalf("semantic copy escaped its SDK owner: %s", source)
		}
	}
	for _, reference := range capture.ProofReferences {
		if reference.Status != "NOT_EXECUTED" {
			t.Fatal("source names became checked proof evidence")
		}
	}
}

func TestProofReferencesDistinguishNotRunFailureAndChangedSource(t *testing.T) {
	for _, status := range []string{"CHECKED", "NOT_EXECUTED", "FAILED", "STALE_SOURCE"} {
		t.Run(status, func(t *testing.T) {
			root, log := leanFixture(t)
			if err := os.WriteFile(log, []byte(leanMessage("'Example.retained' does not depend on any axioms", "information", "Proof.lean")), 0600); err != nil {
				t.Fatal(err)
			}
			evidence, err := readLeanEvidence(root, "Proof.lean", log)
			if err != nil {
				t.Fatal(err)
			}
			results := []Result{{Status: "PASS", Lean: evidence}}
			if status == "NOT_EXECUTED" {
				results = nil
			}
			if status == "FAILED" {
				results[0].Status = "FAIL"
			}
			if status == "STALE_SOURCE" {
				if err := os.WriteFile(filepath.Join(root, "Proof.lean"), []byte("changed"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			refs, err := proofReferences(root, results)
			if err != nil || len(refs) != 1 || refs[0].Status != status {
				t.Fatalf("wrong proof status: %+v %v", refs, err)
			}
		})
	}
}

func TestModelMappingRefusesProofReceiptAfterAnySourceChange(t *testing.T) {
	root, inputs := verificationInputsFixture(t)
	path := latestResultPath(root, "check-policy")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	receipt := Receipt{Root: root, Status: "PASS", Inputs: inputs, Stages: []Result{{Name: "checked-proof", Status: "PASS"}}}
	encoded, err := json.Marshal(receipt)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, encoded, 0600); err != nil {
		t.Fatal(err)
	}
	if results, err := currentLeanResults(root); err != nil || len(results) != 1 {
		t.Fatalf("current receipt refused: %v", err)
	}
	for _, source := range []string{"Project.sysml", "dev/sysml/runtime-trace.json", "dev/proofs/lean/StreamingExecution.lean", "go/internal/devrunner/lean.go", "docs/architecture/diagrams/00a-readme-overview.d2"} {
		t.Run(source, func(t *testing.T) {
			full := filepath.Join(root, source)
			body, err := os.ReadFile(full)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(full, append(body, '\n'), 0600); err != nil {
				t.Fatal(err)
			}
			if results, err := currentLeanResults(root); err != nil || len(results) != 0 {
				t.Fatalf("stale source admitted: %+v %v", results, err)
			}
			if err := os.WriteFile(full, body, 0600); err != nil {
				t.Fatal(err)
			}
		})
	}
	if results, err := currentLeanResults(root); err != nil || len(results) != 1 {
		t.Fatal("restored exact source did not recover the same conditional proof receipt")
	}
}
