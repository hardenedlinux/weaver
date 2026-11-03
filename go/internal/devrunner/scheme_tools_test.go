package devrunner

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestSchemeToolReceiptUsesBuildPathAndDirectory(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix SDK tool executable modes")
	}
	root := t.TempDir()
	file, err := os.CreateTemp(root, "")
	if err != nil {
		t.Fatal(err)
	}
	real := file.Name()
	file.Close()
	if err := os.Chmod(real, 0700); err != nil {
		t.Fatal(err)
	}
	links, err := os.MkdirTemp(root, "")
	if err != nil {
		t.Fatal(err)
	}
	blocked, err := os.MkdirTemp(root, "")
	if err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(links, filepath.Base(real))
	if err := os.Symlink(real, alias); err != nil {
		t.Fatal(err)
	}
	nonexec := filepath.Join(blocked, filepath.Base(real))
	if err := os.WriteFile(nonexec, nil, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", blocked+string(os.PathListSeparator)+links)
	t.Setenv("WEAVER_TEST_SDK_COMPILER", filepath.Base(alias))
	expected, err := filepath.EvalSymlinks(real)
	if err != nil {
		t.Fatal(err)
	}
	checkEnvironment := func(t *testing.T, key string) {
		t.Helper()
		recorded := os.Getenv(key)
		actual, err := resolveBuildTool(root, recorded, os.Environ())
		if err != nil || actual != expected {
			t.Fatalf("%q: got %q want %q: %v", recorded, actual, expected, err)
		}
		if _, err := fileSHA256(actual); err != nil {
			t.Fatal(err)
		}
	}
	t.Run("SDK discovery with CC unset", func(t *testing.T) { t.Setenv("CC", ""); checkEnvironment(t, "WEAVER_TEST_SDK_COMPILER") })
	t.Run("relative environment selection", func(t *testing.T) {
		relative, err := filepath.Rel(root, alias)
		if err != nil {
			t.Fatal(err)
		}
		t.Setenv("CC", relative)
		checkEnvironment(t, "CC")
	})
	t.Run("absolute environment selection", func(t *testing.T) { t.Setenv("CC", real); checkEnvironment(t, "CC") })
	t.Run("nonexecutable environment selection", func(t *testing.T) {
		t.Setenv("CC", nonexec)
		if _, err := resolveBuildTool(root, os.Getenv("CC"), os.Environ()); err == nil {
			t.Fatal("nonexecutable tool accepted")
		}
	})
	t.Run("empty unresolved selection", func(t *testing.T) {
		t.Setenv("CC", "")
		if _, err := resolveBuildTool(root, os.Getenv("CC"), os.Environ()); err == nil {
			t.Fatal("empty tool accepted")
		}
	})
}

func TestSchemeQualificationStaysWithPreparedSchemeOwner(t *testing.T) {
	stages, err := Stages("check-scheme", "go")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, stage := range stages {
		if stage.Name == "scheme-rooted-sdk-integration" {
			args := strings.Join(stage.Args, " ")
			found = strings.Contains(args, "weaver-governance/scheme-qualification") && strings.Contains(args, "weaver-server/governance-qualification") && strings.Contains(args, "-p weaver-server")
		}
	}
	if !found {
		t.Fatal("prepared Scheme owner lost native SDK qualification")
	}
	runtime, err := Stages("check-rust", "go")
	if err != nil {
		t.Fatal(err)
	}
	for _, stage := range runtime {
		if stage.Name == "rust-tests" || stage.Name == "rust-clippy" {
			args := strings.Join(stage.Args, " ")
			if strings.Contains(args, "--all-features") || !strings.Contains(args, "weaver-server/arrow,weaver-governance/scheme-vm") {
				t.Fatal("runtime coverage includes test graph or loses Arrow/converter")
			}
		}
	}
}

func TestSchemeVerificationUsesOnlyPublicPackageEntries(t *testing.T) {
	stages, err := Stages("check-scheme", "go")
	if err != nil {
		t.Fatal(err)
	}
	entries := map[string]string{}
	for _, stage := range stages {
		args := strings.Join(stage.Args, " ")
		for _, forbidden := range []string{"deps --install", "gxpkg", "gebril-yuanxu", "gerbil-poo", "compile_scheme"} {
			if strings.Contains(args, forbidden) {
				t.Fatalf("verification manages transitive packages: %s", stage.Name)
			}
		}
		if stage.Binary == schemeTool() {
			entries[stage.Name] = args
		}
	}
	if len(entries) != 3 || entries["scheme-source-integration-tests"] != "test -g -v 5 t/integration" || entries["scheme-module-build"] != "build -g" || entries["scheme-unit-tests"] != "test -g -v 5 t" {
		t.Fatalf("unexpected Scheme package lifecycle: %v", entries)
	}
}
