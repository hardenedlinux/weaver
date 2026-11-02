//go:build schemeintegration && !windows

package devrunner

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSchemePkgConfigUsesCargoAndEnvironment(t *testing.T) {
	working, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(working)
	if err != nil {
		t.Fatal(err)
	}
	directory, err := os.MkdirTemp(t.TempDir(), "workspace ")
	if err != nil {
		t.Fatal(err)
	}
	library, err := os.CreateTemp(directory, "")
	if err != nil {
		t.Fatal(err)
	}
	library.Close()
	include, err := os.MkdirTemp(directory, "")
	if err != nil {
		t.Fatal(err)
	}
	metadata := filepath.Join(directory, "policy.pc")
	settings := map[string]string{"WEAVER_POLICY_LIBRARY": library.Name(), "WEAVER_POLICY_INCLUDE_DIR": include, "WEAVER_POLICY_PKG_CONFIG": metadata}
	settings["PKG_CONFIG_PATH"] = filepath.Dir(metadata)
	settings["WEAVER_POLICY_PKG_CONFIG_PACKAGE"] = strings.TrimSuffix(filepath.Base(metadata), ".pc")
	build := exec.CommandContext(t.Context(), "cargo", "run", "--locked", "--offline", "-p", "weaver-policy-ffi", "--example", "policy_pkg_config")
	build.Dir = root
	build.Env = Environment(settings)
	if body, err := build.CombinedOutput(); err != nil {
		t.Fatalf("metadata producer: %v: %s", err, body)
	}
	query := func(argument string) string {
		t.Helper()
		command := exec.CommandContext(t.Context(), "pkg-config", argument, settings["WEAVER_POLICY_PKG_CONFIG_PACKAGE"])
		command.Env = Environment(settings)
		body, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("pkg-config %s: %v: %s", argument, err, body)
		}
		return strings.TrimSpace(string(body))
	}
	if query("--variable=library") != library.Name() || query("--variable=includedir") != include {
		t.Fatal("pkg-config substituted the environment-selected artifact")
	}
	command := exec.CommandContext(t.Context(), "cargo", "metadata", "--format-version=1", "--no-deps", "--locked", "--offline")
	command.Dir = root
	body, err := command.Output()
	if err != nil {
		t.Fatal(err)
	}
	var workspace struct {
		Packages []struct{ Name, Version string }
	}
	if err := json.Unmarshal(body, &workspace); err != nil {
		t.Fatal(err)
	}
	version := ""
	for _, pkg := range workspace.Packages {
		if pkg.Name == "weaver-policy-ffi" {
			version = pkg.Version
		}
	}
	if version == "" || query("--modversion") != version {
		t.Fatal("pkg-config version is not driven by Cargo workspace metadata")
	}
	if !strings.Contains(query("--libs"), "\\ ") || !strings.Contains(query("--cflags"), "\\ ") {
		t.Fatal("environment paths containing spaces lost argument boundaries")
	}
}
