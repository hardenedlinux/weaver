package dev

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/Open-MBEE/OpenSysML/client/opensysml"
)

type requirementTrace struct {
	ID        string `json:"id"`
	Witnesses []struct{ File, Pattern string }
}

func TestSysMLSDKAndRequirementTrace(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client, err := opensysml.New(opensysml.WithCacheSize(2))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	model := projectModel(t, ctx, client)
	declared := map[string]bool{}
	diagnostics, err := client.Diagnostics(ctx, model)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range diagnostics {
		if d.Severity == opensysml.SeverityError {
			t.Fatal(d.String())
		}
	}
	requirements, err := client.Query(ctx, model, opensysml.Query{
		Select: []string{"name"}, Where: opensysml.Equals("@type", "RequirementDefinition"),
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, requirement := range requirements {
		name := requirement.Properties["name"]
		if name == "" || declared[name] {
			t.Fatalf("anonymous or ambiguous requirement: %s", requirement.ID)
		}
		declared[name] = true
	}
	traces := readJSON[[]requirementTrace](t, filepath.Join(root(t), "dev/sysml/runtime-trace.json"))
	if len(declared) != len(traces) {
		t.Fatalf("SDK requirement inventory %v differs from trace count %d", declared, len(traces))
	}
	mapped := map[string]bool{}
	for _, trace := range traces {
		if !declared[trace.ID] || mapped[trace.ID] || len(trace.Witnesses) == 0 {
			t.Fatalf("unmapped, duplicate or empty requirement: %s", trace.ID)
		}
		mapped[trace.ID] = true
		for _, witness := range trace.Witnesses {
			if !filepath.IsLocal(witness.File) {
				t.Fatalf("nonlocal witness: %s", witness.File)
			}
			data, err := os.ReadFile(filepath.Join(root(t), witness.File))
			if err != nil {
				t.Fatal(err)
			}
			pattern, err := regexp.Compile(witness.Pattern)
			if err != nil {
				t.Fatal(err)
			}
			if !pattern.Match(data) {
				t.Fatalf("missing named witness for %s: %s", trace.ID, witness.File)
			}
		}
	}
	t.Logf("Strict in-process SDK analysis and named trace coverage: %d requirements; no behavioral refinement proof implied", len(mapped))
}

func TestSysMLSDKRejectsSemanticErrors(t *testing.T) {
	client, err := opensysml.New(opensysml.WithCacheSize(1))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	model, err := client.ParseSource(context.Background(), "package Broken { part x : Missing; }", opensysml.WithStrictConformance())
	if err != nil {
		t.Fatal(err)
	} // Syntax and semantic rejection are model diagnostics, not transport errors.
	if model.OK() || len(model.Errors()) == 0 {
		t.Fatal("negative control admitted an unresolved type")
	}
	found := false
	for _, d := range model.Errors() {
		if strings.Contains(d.Message, "Missing") {
			found = true
		}
	}
	if !found {
		t.Fatalf("missing expected unresolved-type evidence: %v", model.Errors())
	}
}

// Check ownership through the linked SDK model, rather than a second manifest.
// This guards architecture allocation; it does not establish runtime refinement.
func TestSysMLSemanticResponsibilityAllocation(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client, err := opensysml.New(opensysml.WithCacheSize(1))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	model := projectModel(t, ctx, client)
	actions, err := client.Query(ctx, model, opensysml.Query{
		Scope: []string{"WeaverExecution"}, Select: []string{"name", "owner", "type"},
		Where: opensysml.Equals("@type", "ActionUsage"),
	})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"WeaverExecution::SchemeSemanticPublisher::deriveCandidate": "WeaverExecution::DeriveSemanticCandidate",
		"WeaverExecution::GoControlAdapter::publishCandidate":       "WeaverExecution::OrchestrateSourcePublication",
		"WeaverExecution::RustLedger::commitOriginal":               "WeaverExecution::CommitOriginalAdmission",
		"WeaverExecution::RustFinalBroker::guardEffect":             "WeaverExecution::GuardFinalEffect",
	}
	for _, action := range actions {
		key := action.Properties["owner"] + "::" + action.Properties["name"]
		if expected, ok := want[key]; ok {
			if action.Properties["type"] != expected {
				t.Fatalf("%s has type %q, want %s", key, action.Properties["type"], expected)
			}
			delete(want, key)
			continue
		}
		if action.Properties["type"] == "WeaverExecution::GuardFinalEffect" {
			t.Fatalf("final-effect action allocated outside the Rust broker: %s", key)
		}
	}
	if len(want) != 0 {
		t.Fatalf("missing semantic/publication/commit/final-effect allocations: %v; SDK actions: %v", want, actions)
	}
}
