package devrunner

import (
	"os"
	"path/filepath"
	"runtime"
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
