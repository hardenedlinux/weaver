// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestCommittedSourceRejectsReplacementObjects(t *testing.T) {
	root := t.TempDir()
	sourceGit(t, root, "init", "--quiet")
	commit := func(content string) (string, string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, "source.go"), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
		sourceGit(t, root, "add", "source.go")
		sourceGit(t, root, "commit", "--quiet", "-m", content)
		digest := fmt.Sprintf("%x", sha256.Sum256([]byte(content)))
		result, revision := committedSource(context.Background(), root, t.TempDir(), "source", "", map[string]string{"source.go": digest})
		if result.Status != "PASS" {
			t.Fatal(result)
		}
		return revision, digest
	}
	original, _ := commit("package original\n")
	replacement, digest := commit("package replacement\n")
	sourceGit(t, root, "replace", original, replacement)
	sourceGit(t, root, "update-ref", "HEAD", original)
	result, revision := committedSource(context.Background(), root, t.TempDir(), "source", original, map[string]string{"source.go": digest})
	if result.Status != "FAIL" || revision != original {
		t.Fatalf("replacement tree admitted as original revision: %+v", result)
	}
}
