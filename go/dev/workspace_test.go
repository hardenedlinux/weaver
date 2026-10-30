package dev

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/HardenedLinux/weaver/go/internal/devrunner"
)

func tool(t *testing.T, binary string, args ...string) []byte {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, args...)
	cmd.Dir = root(t)
	data, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v: %v: %s", binary, args, err, data)
	}
	return data
}

type cargoDependency struct {
	Name   string
	Kind   *string
	Source *string
}
type cargoPackage struct {
	ID, Name     string
	ManifestPath string `json:"manifest_path"`
	Dependencies []cargoDependency
	Targets      []struct {
		Name string
		Kind []string
	}
}
type cargoNode struct {
	ID   string
	Deps []struct {
		Pkg   string
		Kinds []struct{ Kind *string } `json:"dep_kinds"`
	}
}
type cargoMetadata struct {
	Packages []cargoPackage
	Members  []string `json:"workspace_members"`
	Resolve  struct{ Nodes []cargoNode }
}

func TestCargoWorkspaceAndDevelopmentGates(t *testing.T) {
	var metadata cargoMetadata
	if err := json.Unmarshal(tool(t, "cargo", "metadata", "--locked", "--offline", "--format-version", "1"), &metadata); err != nil {
		t.Fatal(err)
	}
	packages := map[string]cargoPackage{}
	nodes := map[string]cargoNode{}
	for _, p := range metadata.Packages {
		packages[p.ID] = p
	}
	for _, n := range metadata.Resolve.Nodes {
		nodes[n.ID] = n
	}
	members := make([]string, 0, len(metadata.Members))
	for _, id := range metadata.Members {
		members = append(members, packages[id].Name)
	}
	if err := devrunner.ValidateBenchmarkPackages(members); err != nil {
		t.Fatal(err)
	}
	layers := projectRustLayers(t)
	if len(metadata.Members) != len(layers) {
		t.Fatal("unmapped native workspace members")
	}
	inherited := regexp.MustCompile(`^[A-Za-z0-9_-]+(?:\.workspace\s*=\s*true|\s*=\s*\{\s*workspace\s*=\s*true,\s*optional\s*=\s*true\s*\})\s*$`)
	aspPin := regexp.MustCompile(`[?&]rev=[a-f0-9]{40}(?:$|&)`)
	for _, id := range metadata.Members {
		p := packages[id]
		packagePath, err := filepath.Rel(root(t), filepath.Dir(p.ManifestPath))
		if err != nil {
			t.Fatal(err)
		}
		expected, known := layers[filepath.ToSlash(packagePath)]
		if !known {
			t.Fatalf("unmapped crate: %s", p.Name)
		}
		data, err := os.ReadFile(p.ManifestPath)
		if err != nil {
			t.Fatal(err)
		}
		scan := bufio.NewScanner(strings.NewReader(string(data)))
		dependencies := false
		for scan.Scan() {
			line := strings.TrimSpace(strings.SplitN(scan.Text(), "#", 2)[0])
			if strings.HasPrefix(line, "[") {
				dependencies = strings.Contains(line, "dependencies")
				continue
			}
			if dependencies && line != "" && !inherited.MatchString(line) {
				t.Fatalf("dependency not inherited from workspace: %s: %s", p.Name, line)
			}
		}
		if err := scan.Err(); err != nil {
			t.Fatal(err)
		}
		actual := map[string]bool{}
		asp, criterion := 0, 0
		for _, d := range p.Dependencies {
			if d.Kind == nil && strings.HasPrefix(d.Name, "weaver-") {
				actual[d.Name] = true
			}
			if d.Name == "asp-rust" {
				asp++
				if d.Kind == nil || *d.Kind != "dev" || d.Source == nil || !aspPin.MatchString(*d.Source) {
					t.Fatalf("invalid ASP development edge: %s", p.Name)
				}
			}
			if d.Name == "criterion" {
				criterion++
				if d.Kind == nil || *d.Kind != "dev" {
					t.Fatalf("Criterion must be development-only: %s", p.Name)
				}
			}
		}
		wanted := map[string]bool{}
		for _, name := range strings.Split(expected, ",") {
			if name != "" {
				wanted[name] = true
			}
		}
		if len(actual) != len(wanted) {
			t.Fatalf("runtime layer mismatch: %s", p.Name)
		}
		for name := range wanted {
			if !actual[name] {
				t.Fatalf("missing runtime edge: %s -> %s", p.Name, name)
			}
		}
		if asp != 1 {
			t.Fatalf("missing unique ASP development gate: %s", p.Name)
		}
		bench := false
		for _, target := range p.Targets {
			for _, kind := range target.Kind {
				if kind == "bench" && target.Name == "gateway" {
					bench = true
				}
			}
		}
		if criterion != 1 || !bench {
			t.Fatalf("missing executable benchmark: %s", p.Name)
		}
		benchRoot := filepath.Join(filepath.Dir(p.ManifestPath), "benches")
		for _, name := range []string{"gateway.rs", "README.org"} {
			info, err := os.Stat(filepath.Join(benchRoot, name))
			if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
				t.Fatalf("missing package benchmark asset: %s/%s: %v", p.Name, name, err)
			}
		}
		contract, err := os.ReadFile(filepath.Join(benchRoot, "README.org"))
		if err != nil {
			t.Fatal(err)
		}
		for _, section := range []string{"#+LANGUAGE: en", "* Workload", "* Measurement boundary", "* Entrypoints"} {
			if !strings.Contains(string(contract), section) {
				t.Fatalf("missing benchmark contract section: %s: %s", p.Name, section)
			}
		}
		seen := map[string]bool{}
		todo := []string{id}
		for len(todo) > 0 {
			next := todo[0]
			todo = todo[1:]
			if seen[next] {
				continue
			}
			seen[next] = true
			if packages[next].Name == "asp-rust" || packages[next].Name == "criterion" {
				t.Fatalf("ASP in production dependency graph: %s", p.Name)
			}
			for _, edge := range nodes[next].Deps {
				for _, kind := range edge.Kinds {
					if kind.Kind == nil {
						todo = append(todo, edge.Pkg)
						break
					}
				}
			}
		}
		gate, err := os.ReadFile(filepath.Join(filepath.Dir(p.ManifestPath), "src/lib.rs"))
		if err != nil {
			t.Fatal(err)
		}
		for _, required := range []string{"#[cfg(test)]", "asp_rust_cargo_test_gate!", "mode = deny"} {
			if !strings.Contains(string(gate), required) {
				t.Fatalf("missing ASP gate %s: %s", required, p.Name)
			}
		}
		for _, forbidden := range []string{"advice = allow", "with_disabled"} {
			if strings.Contains(string(gate), forbidden) {
				t.Fatalf("weakened ASP gate: %s", p.Name)
			}
		}
	}
}
func TestSysMLSDKIsAbsentFromProductionBuild(t *testing.T) {
	goBinary := filepath.Join(runtime.GOROOT(), "bin/go")
	deps := tool(t, goBinary, "-C", "go", "list", "-deps", "./cmd/...")
	if strings.Contains(string(deps), "github.com/Open-MBEE/OpenSysML") {
		t.Fatal("development SDK leaked into production command graph")
	}
}
