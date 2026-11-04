// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func leanFixture(t *testing.T) (string, string) {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "dev/sysml"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "dev/sysml/runtime-trace.json"), []byte(`[{"id":"Original","witnesses":[{"file":"Proof.lean","declaration":"Example.retained"}]}]`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "Proof.lean"), []byte("theorem retained : True := True.intro\n"), 0600); err != nil {
		t.Fatal(err)
	}
	return root, filepath.Join(root, "proof.jsonl")
}

func leanMessage(data, severity, file string) string {
	value := LeanDiagnostic{Data: data, Severity: severity, FileName: file}
	value.Pos.Line = 1
	encoded, _ := json.Marshal(value)
	return string(encoded) + "\n"
}

func TestLeanJSONEvidenceRejectsUnprovenOrUnboundMessages(t *testing.T) {
	good := leanMessage("'Example.retained' depends on axioms: [propext, Quot.sound]", "information", "Proof.lean")
	for name, text := range map[string]string{
		"valid":                good,
		"valid-multiline":      leanMessage("'Example.retained' depends on axioms: [propext,\n Classical.choice,\n Quot.sound]", "information", "Proof.lean"),
		"non-json":             "OK\n",
		"empty":                "",
		"wrong-source":         strings.ReplaceAll(good, "Proof.lean", "Other.lean"),
		"unknown-severity":     strings.ReplaceAll(good, "information", "success"),
		"error-despite-audit":  good + leanMessage("unsolved goals", "error", "Proof.lean"),
		"sorry-warning":        good + leanMessage("declaration uses 'sorry'", "warning", "Proof.lean"),
		"sorry-axiom":          strings.ReplaceAll(good, "propext", "sorryAx"),
		"custom-axiom":         strings.ReplaceAll(good, "propext", "Unproved.assumption"),
		"duplicate":            good + good,
		"untraced-declaration": strings.ReplaceAll(good, "Example.retained", "Example.other"),
	} {
		t.Run(name, func(t *testing.T) {
			root, log := leanFixture(t)
			if err := os.WriteFile(log, []byte(text), 0600); err != nil {
				t.Fatal(err)
			}
			evidence, err := readLeanEvidence(root, "Proof.lean", log)
			if !strings.HasPrefix(name, "valid") {
				if err == nil {
					t.Fatal("invalid proof evidence admitted")
				}
				return
			}
			if err != nil || evidence.SourceSHA256 == "" || len(evidence.Declarations) != 1 || evidence.Declarations[0].Name != "Example.retained" {
				t.Fatalf("lost source/declaration evidence: %+v %v", evidence, err)
			}
			if len(evidence.Declarations[0].Requirements) != 1 || evidence.Declarations[0].Requirements[0] != "Original" {
				t.Fatal("requirement identity did not reach proof receipt")
			}
		})
	}
}

func FuzzLeanJSONSourceAndDeclarationBinding(f *testing.F) {
	f.Add("Proof.lean", "Example.retained", "information")
	f.Add("Other.lean", "Example.retained", "information")
	f.Add("Proof.lean", "Example.replaced", "information")
	f.Fuzz(func(t *testing.T, source, declaration, severity string) {
		if len(source)+len(declaration)+len(severity) > 4096 || strings.ContainsAny(declaration, "'\n\r[]") {
			t.Skip()
		}
		root, log := leanFixture(t)
		if err := os.WriteFile(log, []byte(leanMessage("'"+declaration+"' does not depend on any axioms", severity, source)), 0600); err != nil {
			t.Fatal(err)
		}
		_, err := readLeanEvidence(root, "Proof.lean", log)
		if err == nil && (filepath.Clean(source) != "Proof.lean" || declaration != "Example.retained" || (severity != "information" && severity != "warning")) {
			t.Fatal("source or declaration substituted")
		}
	})
}

func TestLeanPlanUsesStructuredEvidenceInPolicyLane(t *testing.T) {
	for _, mode := range []string{"check-go", "check-policy"} {
		stages, err := Stages(mode, "configured-go")
		if err != nil {
			t.Fatal(err)
		}
		proofs, controls := 0, 0
		for _, stage := range stages {
			if leanSource(stage) != "" {
				proofs++
			}
			if stage.Name == "lean-json-integration" {
				controls++
			}
		}
		if mode == "check-policy" && (proofs != 7 || controls != 1) {
			t.Fatalf("policy lane lost machine proof evidence: %d/%d", proofs, controls)
		}
		if mode == "check-go" && (proofs != 0 || controls != 0) {
			t.Fatal("Go-only lane acquired proof toolchain requirements")
		}
	}
}
