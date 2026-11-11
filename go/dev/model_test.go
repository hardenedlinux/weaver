// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

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
