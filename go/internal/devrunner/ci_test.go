// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"context"
	"io"
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
			if covered[stage.Name] && stage.Name != "project-architecture" && stage.Name != "workflow-contract" {
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
