package devrunner

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestModuleRegistryRejectsAmbiguousAndEscapingIdentities(t *testing.T) {
	for _, body := range []string{"", "../escape\t/tmp/escape.o1", "/absolute\t/tmp/a.o1", "a//b\t/tmp/a.o1", "a\trelative.o1", "a\t/tmp/a.o1\na\t/tmp/other.o1", "a\t/tmp/a.o1\textra"} {
		if _, err := readModuleRegistry([]byte(body)); err == nil {
			t.Errorf("accepted malformed registry %q", body)
		}
	}
	modules, err := readModuleRegistry([]byte("core/runtime~0\t/tmp/runtime~0.o1\n"))
	if err != nil || modules["core/runtime~0"] != "/tmp/runtime~0.o1" {
		t.Fatal("valid phase identity rejected", err)
	}
}

func TestImageToolReceiptUsesBuildPathAndDirectory(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Darwin image compiler executable modes")
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
		actual, err := resolveImageTool(root, recorded, os.Environ())
		if err != nil || actual != expected {
			t.Fatalf("%q: got %q want %q: %v", recorded, actual, expected, err)
		}
		if _, err := imageFileHash(actual); err != nil {
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
		if _, err := resolveImageTool(root, os.Getenv("CC"), os.Environ()); err == nil {
			t.Fatal("nonexecutable tool accepted")
		}
	})
	t.Run("empty unresolved selection", func(t *testing.T) {
		t.Setenv("CC", "")
		if _, err := resolveImageTool(root, os.Getenv("CC"), os.Environ()); err == nil {
			t.Fatal("empty tool accepted")
		}
	})
}

func TestDynamicImagesRetainForeignAndMacroPreludeOwners(t *testing.T) {
	for _, source := range []string{`(c-declare "#include <weaver_policy.h>")`, `(c-lambda (int) int "function")`, `(macro-thread-end-condvar thread)`, `"macro-absent-obj"`} {
		if imageExclusion([]byte(source)) == "" {
			t.Errorf("lost compiler-option boundary for %s", source)
		}
	}
	if imageExclusion([]byte(`(define (identity value) value)`)) != "" {
		t.Fatal("pure generated module excluded")
	}
}
