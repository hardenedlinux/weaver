package dev

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectArchitectureLicensing(t *testing.T) {
	const expression = "LGPL-2.1-or-later OR Apache-2.0"
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
		t.Fatal("repository SPDX choice/copyright mismatch")
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
	paths := strings.Split(strings.TrimSpace(string(tool(t, "git", "ls-files", "--", "scheme", "t", "build.ss", "init.ss", "gerbil.pkg"))), "\n")
	for _, path := range paths {
		if !strings.HasSuffix(path, ".ss") && path != "gerbil.pkg" {
			continue
		}
		text := read(path)
		if !strings.Contains(text, ";;; SPDX-FileCopyrightText: "+owner) || !strings.Contains(text, ";;; SPDX-License-Identifier: "+expression) {
			t.Fatal("Scheme SPDX header mismatch", path)
		}
	}
	if !strings.HasPrefix(read("build.ss"), "#!/usr/bin/env gxi\n") {
		t.Fatal("package build shebang changed")
	}
}
