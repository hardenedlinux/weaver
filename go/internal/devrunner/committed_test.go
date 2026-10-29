package devrunner

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func sourceGit(t *testing.T, root string, args ...string) {
	t.Helper()
	base := []string{"-C", root, "-c", "user.name=Weaver fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"}
	cmd := exec.Command("git", append(base, args...)...)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("fixture git: %v: %s", err, output)
	}
}

func TestCommittedSourceRejectsHiddenMutationAndUncommittedInputs(t *testing.T) {
	root := t.TempDir()
	sourceGit(t, root, "init", "--quiet")
	file := "source file.go"
	write := func(name, value string) string {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, name), []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
		return fmt.Sprintf("%x", sha256.Sum256([]byte(value)))
	}
	original := write(file, "package original\n")
	sourceGit(t, root, "add", "--", file)
	sourceGit(t, root, "commit", "--quiet", "-m", "source fixture")
	check := func(expected string, inputs map[string]string) (Result, string) {
		t.Helper()
		return committedSource(context.Background(), root, t.TempDir(), "source", expected, inputs)
	}
	good, revision := check("", map[string]string{file: original})
	if good.Status != "PASS" || revision == "" {
		t.Fatalf("committed source rejected: %+v", good)
	}
	sourceGit(t, root, "update-index", "--assume-unchanged", "--", file)
	changed := write(file, "package changed\n")
	bad, _ := check(revision, map[string]string{file: changed})
	if bad.Status != "FAIL" {
		t.Fatal("index-hidden source mutation accepted")
	}
	ignored := write("ignored.go", "package ignored\n")
	write(".gitignore", "ignored.go\n")
	bad, _ = check(revision, map[string]string{"ignored.go": ignored})
	if bad.Status != "FAIL" {
		t.Fatal("ignored compiler input accepted as committed")
	}
	sourceGit(t, root, "commit", "--quiet", "--allow-empty", "-m", "new revision")
	bad, _ = check(revision, map[string]string{file: original})
	if bad.Status != "FAIL" {
		t.Fatal("changed source head accepted")
	}
}
