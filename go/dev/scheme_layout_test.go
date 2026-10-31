package dev

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestSchemeModuleOwnershipAndSpecificContracts(t *testing.T) {
	repository := root(t)
	for _, name := range []string{"gerbil.pkg", "build.ss", "init.ss"} {
		info, err := os.Stat(filepath.Join(repository, name))
		if err != nil || !info.Mode().IsRegular() {
			t.Fatalf("missing root Scheme package entry %s: %v", name, err)
		}
	}
	expected := map[string]bool{}
	for path := range projectLayout(projectParts(t), "SchemeModule") {
		expected[filepath.Base(path)] = true
	}
	entries, err := os.ReadDir(filepath.Join(repository, "scheme"))
	if err != nil {
		t.Fatal(err)
	}
	generic := regexp.MustCompile(`\bAny\b`)
	for _, entry := range entries {
		if !entry.IsDir() || !expected[entry.Name()] {
			t.Fatalf("Scheme directory is a module collection, unexpected owner: %s", entry.Name())
		}
		directory := filepath.Join(repository, "scheme", entry.Name())
		if _, err := os.Stat(filepath.Join(directory, "gerbil.pkg")); !os.IsNotExist(err) {
			t.Fatal("nested package root inside a Scheme module")
		}
		for _, role := range []string{"types", "objects", "func", "config", "interface"} {
			data, err := os.ReadFile(filepath.Join(directory, role+".ss"))
			if err != nil || len(data) == 0 {
				t.Fatalf("module %s missing %s role: %v", entry.Name(), role, err)
			}
			if role == "types" && (generic.Match(data) || !strings.Contains(string(data), "(Record") || !strings.Contains(string(data), "(Function")) {
				t.Fatalf("module %s lacks specific native Record/Function contracts", entry.Name())
			}
		}
		delete(expected, entry.Name())
	}
	if len(expected) != 0 {
		t.Fatalf("missing Scheme module owners: %v", expected)
	}
	build, err := os.ReadFile(filepath.Join(repository, "build.ss"))
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"./init.ss", "std-make-spec", "defbuild-script", "scheme/policy/cedar-ffi", "pkg-config-cflags", "pkg-config-libs"} {
		if !strings.Contains(string(build), required) {
			t.Fatalf("root build does not use its declared owner: %s", required)
		}
	}
	info, err := os.Stat(filepath.Join(repository, "build.ss"))
	if err != nil || info.Mode()&0111 == 0 || !strings.HasPrefix(string(build), "#!/usr/bin/env gxi\n") || strings.Contains(string(build), "(def (main") {
		t.Fatal("root must use Gerbil's generated standard build entry")
	}
	if strings.Contains(string(build), "target/debug") {
		t.Fatal("Scheme build must obtain FFI paths from pkg-config")
	}
	if strings.Contains(string(build), "exe:") || strings.Contains(string(build), "bin:") {
		t.Fatal("FFI-loaded governance libraries must not acquire executable build targets")
	}
	for _, retired := range []string{"dev/build.ss", "dev/gerbil.pkg"} {
		if _, err := os.Stat(filepath.Join(repository, retired)); !os.IsNotExist(err) {
			t.Fatalf("unneeded Scheme executable package remains: %s", retired)
		}
	}
}
