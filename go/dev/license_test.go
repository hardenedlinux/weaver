// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package dev

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestProjectArchitectureLicensing(t *testing.T) {
	const expression = "LGPL-2.1-or-later AND Apache-2.0"
	const owner = "2026 hardenedlinux Linux Team and Contributors"
	read := func(path string) string {
		t.Helper()
		data, err := os.ReadFile(filepath.Join(root(t), path))
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	notice := read("LICENSE")
	if !strings.Contains(notice, "SPDX-License-Identifier: "+expression) || !strings.Contains(notice, "SPDX-FileCopyrightText: "+owner) {
		t.Fatal("repository SPDX expression/copyright mismatch")
	}
	for path, title := range map[string]string{"LICENSES/LGPL-2.1-or-later.txt": "GNU LESSER GENERAL PUBLIC LICENSE", "LICENSES/Apache-2.0.txt": "Apache License"} {
		text := read(path)
		if !strings.Contains(text, title) || len(text) < 9000 {
			t.Fatal("complete license text missing", path)
		}
	}
	var renderer struct {
		License string `json:"license"`
	}
	if err := json.Unmarshal([]byte(read("dev/d2/package.json")), &renderer); err != nil || renderer.License != expression {
		t.Fatal("renderer SPDX metadata mismatch", err)
	}
	reuse := read("REUSE.toml")
	if !strings.Contains(reuse, `precedence = "closest"`) || strings.Contains(reuse, `precedence = "override"`) || !strings.Contains(reuse, `SPDX-License-Identifier = "`+expression+`"`) {
		t.Fatal("first-party SPDX fallback must preserve local notices")
	}
	paths := strings.Split(strings.TrimSpace(string(tool(t, "git", "ls-files", "--cached", "--others", "--exclude-standard"))), "\n")
	copyright := regexp.MustCompile(`(?m)^(?:// |# |;;; |-- )?SPDX-FileCopyrightText: .+`)
	identifier := regexp.MustCompile(`(?m)^(?:// |# |;;; |-- )?SPDX-License-Identifier: .+`)
	for _, path := range paths {
		// Preserve captured evidence, canonical license texts and third-party marks.
		if strings.HasPrefix(path, "dev/proofs/evidence/") || strings.HasPrefix(path, "dev/specs/evidence/") || strings.HasPrefix(path, "LICENSES/") {
			continue
		}
		if strings.HasPrefix(path, "go/") && strings.Contains(path, "/testdata/fuzz/") {
			if strings.HasSuffix(path, ".license") || !strings.Contains(reuse, `"go/**/testdata/fuzz/**"`) {
				t.Fatal("Go fuzz requires format-preserving SPDX scope without sibling metadata", path)
			}
			continue
		}
		switch path {
		case "docs/architecture/diagrams/assets/go.svg", "docs/architecture/diagrams/assets/rust.svg", "docs/architecture/diagrams/assets/kubernetes.svg":
			continue
		}
		t.Run(path, func(t *testing.T) {
			noticePath := path
			if _, err := os.Stat(filepath.Join(root(t), path+".license")); err == nil {
				noticePath += ".license"
			}
			text := read(noticePath)
			// Require a real leading notice, not tags in documentation or string literals.
			if len(text) > 1024 {
				text = text[:1024]
			}
			if !copyright.MatchString(text) || !identifier.MatchString(text) {
				t.Fatal("missing leading SPDX copyright/license notice", noticePath)
			}
		})
	}
	if !strings.HasPrefix(read("build.ss"), "#!/usr/bin/env gxi\n") {
		t.Fatal("package build shebang changed")
	}
}
