// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package dev

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/HardenedLinux/weaver/go/internal/devrunner"
	"gopkg.in/yaml.v3"
)

type suiteWorkflow struct {
	Name string `yaml:"name"`
	Jobs map[string]struct {
		Name  string    `yaml:"name"`
		Uses  string    `yaml:"uses"`
		Needs yaml.Node `yaml:"needs"`
		With  struct {
			Suite  string `yaml:"suite"`
			Runner string `yaml:"runner"`
		} `yaml:"with"`
		Strategy struct {
			Matrix struct {
				Runner []string `yaml:"runner"`
			} `yaml:"matrix"`
		} `yaml:"strategy"`
	} `yaml:"jobs"`
}

func TestCIWorkflowsMatchProjectSuites(t *testing.T) {
	parts := projectParts(t)
	wanted := map[string]string{}
	for _, part := range parts {
		if part.Properties["owner"] != projectNamespace+"Verification" || projectKind(part) != "VerificationSuite" {
			continue
		}
		for _, child := range parts {
			if child.Properties["owner"] == part.ID && projectKind(child) == "VerificationMode" {
				wanted[part.Properties["name"]] = child.Properties["name"]
			}
		}
	}
	data, err := os.ReadFile(filepath.Join(root(t), ".github/workflows/ci.yml"))
	if err != nil {
		t.Fatal(err)
	}
	var workflow suiteWorkflow
	if err := yaml.Unmarshal(data, &workflow); err != nil {
		t.Fatal(err)
	}
	if len(wanted) == 0 || len(workflow.Jobs) != len(wanted) {
		t.Fatal("CI suites differ from Project.sysml")
	}
	for name, mode := range wanted {
		job, ok := workflow.Jobs[name]
		if !ok || job.With.Suite != mode || job.Uses != "./.github/workflows/verify-suite.yml" {
			t.Fatalf("CI allocation mismatch for %s", name)
		}
		if job.Needs.Kind != 0 {
			t.Fatalf("independent suite %s is unnecessarily serialized", name)
		}
		for _, runner := range job.Strategy.Matrix.Runner {
			if !strings.HasSuffix(runner, "-latest") {
				t.Fatalf("suite %s pins an operating-system image: %s", name, runner)
			}
		}
		if strings.Contains(strings.ToLower(job.Name), "native") {
			t.Fatalf("non-specific CI namespace for %s", name)
		}
		stages, err := devrunner.Stages(mode, "go")
		if err != nil || len(stages) == 0 {
			t.Fatalf("CI mode %s has no executable checks", mode)
		}
	}
	data, err = os.ReadFile(filepath.Join(root(t), ".github/workflows/verify-suite.yml"))
	if err != nil {
		t.Fatal(err)
	}
	var reusable struct {
		On struct {
			Call struct {
				Inputs map[string]struct {
					Default string `yaml:"default"`
				} `yaml:"inputs"`
			} `yaml:"workflow_call"`
		} `yaml:"on"`
	}
	if err := yaml.Unmarshal(data, &reusable); err != nil {
		t.Fatal(err)
	}
	if reusable.On.Call.Inputs["runner"].Default != "ubuntu-latest" {
		t.Fatal("default suite runner must follow ubuntu-latest")
	}
	for _, path := range []string{".github/workflows/verify-suite.yml", ".github/actions/prepare-toolchain/action.yml"} {
		data, err := os.ReadFile(filepath.Join(root(t), path))
		if err != nil {
			t.Fatal(err)
		}
		for _, retired := range []string{"nix shell", "install-nix-action", "devenv shell", "python3"} {
			if strings.Contains(string(data), retired) {
				t.Fatalf("retired CI startup dependency %q in %s", retired, path)
			}
		}
	}
}
