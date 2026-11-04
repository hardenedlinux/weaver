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
	"testing/quick"
)

func TestSelectedViewImportFollowsSDKRequirement(t *testing.T) {
	property := func(required, selectSecurity, selectLocal bool) bool {
		capture := &ModelViewCapture{Descriptions: map[string]*ModelDescription{
			"security": {File: "security.d2", LeanEnvironment: required},
			"local":    {File: "local.d2"},
		}}
		var selected []string
		if selectSecurity {
			selected = append(selected, "security.d2")
		}
		if selectLocal {
			selected = append(selected, "local.d2")
		}
		return capture.requiresLeanEnvironment(selected) == (required && selectSecurity)
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 128}); err != nil {
		t.Fatal(err)
	}
}

func TestPolicyPlanIncludesMaintainedGatewayBuildAndJSONExport(t *testing.T) {
	stages, err := Stages("check-policy", "go")
	if err != nil {
		t.Fatal(err)
	}
	build, exported := false, false
	for _, stage := range stages {
		if stage.Name == "cedar-proof-bridge" {
			build = strings.Join(stage.Args, " ") == "run "+proofToolchain+" lake -d dev/proofs/cedar build"
		}
		if stage.Name == "lean-architecture-environment" {
			exported = leanSource(stage) == "dev/proofs/cedar/ZeroTrustArchitecture.lean"
		}
	}
	if !build || !exported {
		t.Fatal("ordinary policy gate lost the Gateway composition or actual environment export")
	}
}

func TestLeanEnvironmentRequiresCompilerAndSourceBinding(t *testing.T) {
	for _, scenario := range []string{"valid", "failed", "changed-source", "duplicate", "wrong-schema", "duplicate-field", "wrong-source"} {
		t.Run(scenario, func(t *testing.T) {
			root := t.TempDir()
			source := "dev/proofs/cedar/Export.lean"
			if err := os.MkdirAll(filepath.Dir(filepath.Join(root, source)), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, source), []byte("import CedarPooSpec.Gateway.ZeroTrust\n"), 0600); err != nil {
				t.Fatal(err)
			}
			hash, err := fileSHA256(filepath.Join(root, source))
			if err != nil {
				t.Fatal(err)
			}
			environment := &LeanEnvironment{Schema: "weaver.lean.environment.v1", Declarations: []LeanContract{{Name: "CedarPooSpec.Gateway.ZeroTrust.FinalUse", Type: "Proposal → Type", Fields: []LeanField{{Name: "sameView", Type: "actual = proposal.before"}}}}}
			result := Result{Status: "PASS", Lean: &LeanEvidence{Source: source, SourceSHA256: hash, Environment: environment}}
			switch scenario {
			case "failed":
				result.Status = "FAIL"
			case "changed-source":
				result.Lean.SourceSHA256 = strings.Repeat("0", 64)
			case "duplicate":
				environment.Declarations = append(environment.Declarations, environment.Declarations[0])
			case "wrong-schema":
				environment.Schema = "untrusted"
			case "duplicate-field":
				environment.Declarations[0].Fields = append(environment.Declarations[0].Fields, environment.Declarations[0].Fields[0])
			case "wrong-source":
				result.Lean.Source = "../Export.lean"
			}
			contracts, err := currentLeanEnvironment(root, []Result{result})
			if scenario == "valid" {
				if err != nil || len(contracts) != 1 {
					t.Fatalf("valid export lost: %v", err)
				}
			} else if scenario == "failed" {
				if err != nil || len(contracts) != 0 {
					t.Fatal("failed compiler exported a contract")
				}
			} else if err == nil {
				t.Fatalf("invalid environment accepted: %s", scenario)
			}
		})
	}
}

func TestLeanEnvironmentJSONIsNotJustAnAxiomAudit(t *testing.T) {
	root, log := leanFixture(t)
	environment := LeanEnvironment{Schema: "weaver.lean.environment.v1", Declarations: []LeanContract{{Name: "CedarPooSpec.Gateway.ZeroTrust.FinalUse", Type: "Proposal → Type", Fields: []LeanField{{Name: "sameView", Type: "actual = proposal.before"}}}}}
	payload, err := json.Marshal(environment)
	if err != nil {
		t.Fatal(err)
	}
	audit := leanMessage("'Example.retained' does not depend on any axioms", "information", "Proof.lean")
	for _, scenario := range []string{"valid", "duplicate", "error"} {
		messages := leanMessage(string(payload), "information", "Proof.lean") + audit
		if scenario == "duplicate" {
			messages += leanMessage(string(payload), "information", "Proof.lean")
		}
		if scenario == "error" {
			messages += leanMessage("unknown constant", "error", "Proof.lean")
		}
		if err := os.WriteFile(log, []byte(messages), 0600); err != nil {
			t.Fatal(err)
		}
		evidence, err := readLeanEvidence(root, "Proof.lean", log)
		if scenario == "valid" {
			if err != nil || evidence.Environment == nil || evidence.Environment.Declarations[0].Fields[0].Name != "sameView" {
				t.Fatalf("environment missing: %+v %v", evidence, err)
			}
		} else if err == nil {
			t.Fatalf("invalid compiler stream accepted: %s", scenario)
		}
	}
}

func TestArchitectureEnrichmentIsExplanationWithCheckedReferences(t *testing.T) {
	contract := LeanContract{Name: "CedarPooSpec.Gateway.ZeroTrust.FinalUse", Fields: []LeanField{{Name: "current", Type: "host.currentAtUse actual", Condition: true}, {Name: "mediated", Type: "host.mediated effect actual", Condition: true}}}
	caption := ModelCaption{ID: "broker", Label: "Rust / Final-use guard\nRecheck current authority before external bytes", LeanFields: []string{"current", "mediated"}}
	if err := validateLeanAllocation(caption, contract); err != nil {
		t.Fatal(err)
	}
	for _, fields := range [][]string{nil, {"current"}, {"current", "inventedTrust"}, {"current", "current"}} {
		caption.LeanFields = fields
		if err := validateLeanAllocation(caption, contract); err == nil {
			t.Fatalf("invalid enrichment reference accepted: %v", fields)
		}
	}
}
