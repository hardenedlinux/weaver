// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"context"
	"io"
	"slices"
	"testing"
)

func TestCIPackagePreparationRejectsLocalAndUnknownJobs(t *testing.T) {
	t.Setenv("GITHUB_ACTIONS", "")
	if err := PrepareCITools(context.Background(), io.Discard); err == nil {
		t.Fatal("host package installation accepted outside CI")
	}
	t.Setenv("GITHUB_ACTIONS", "true")
	t.Setenv("RUNNER_ENVIRONMENT", "github-hosted")
	t.Setenv("WEAVER_VERIFY_SUITE", "untrusted-command")
	if err := PrepareCITools(context.Background(), io.Discard); err == nil {
		t.Fatal("unknown job accepted before host mutation")
	}
}

func TestModularCISuitesPreserveUnifiedGateCoverage(t *testing.T) {
	covered := map[string]bool{}
	for _, mode := range []string{"check-rust", "check-go", "check-policy", "check-architecture"} {
		stages, err := Stages(mode, "go")
		if err != nil {
			t.Fatal(err)
		}
		for _, stage := range stages {
			if stage.Binary == "go" && slices.Contains(stage.Args, "test") && !slices.Contains(stage.Args, "-parallel=4") {
				t.Fatalf("expected four Go test workers for %s", stage.Name)
			}
			if covered[stage.Name] && stage.Name != "project-architecture" && stage.Name != "workflow-contract" && !stage.providerBuild() {
				t.Fatalf("unintended duplicated check %s", stage.Name)
			}
			covered[stage.Name] = true
		}
	}
	for _, stage := range Plan("go") {
		if !covered[stage.Name] {
			t.Fatalf("lost unified gate check %s", stage.Name)
		}
	}
}

// Cold preparation must not accidentally use a different Cargo feature graph
// and rebuild it inside the two-minute protocol gate.
func TestConsumerPreparationSharesTheRuntimeCargoGraph(t *testing.T) {
	prepared, err := Stages("prepare-consumers", "configured-go")
	if err != nil || len(prepared) != 2 {
		t.Fatalf("consumer preparation: %v %v", prepared, err)
	}
	checked, err := Stages("check-consumers", "configured-go")
	if err != nil || len(checked) != 1 {
		t.Fatalf("consumer protocol gate: %v %v", checked, err)
	}
	if prepared[0].Binary != "configured-go" || !slices.Contains(prepared[0].Args, "nogui") || !slices.Contains(prepared[0].Args, ".data/magpie") {
		t.Fatal("consumer preparation must use its original Go package entry")
	}
	build := prepared[1]
	run := checked[0]
	if build.Binary != "cargo" || run.Binary != "cargo" || len(build.Args) < 2 || build.Args[len(build.Args)-1] != "--no-run" {
		t.Fatal("missing separate Cargo preparation")
	}
	graph := build.Args[:len(build.Args)-1]
	if len(run.Args) <= len(graph) || !slices.Equal(graph, run.Args[:len(graph)]) {
		t.Fatal("consumer runtime would select a different Cargo graph")
	}
	if !slices.Equal(run.Args[len(graph):], []string{"magpie_standard_provider_preserves_three_protocol_tool_turns", "--", "--ignored", "--test-threads=4"}) {
		t.Fatal("the explicit external consumer must run, not remain ignored")
	}
}
