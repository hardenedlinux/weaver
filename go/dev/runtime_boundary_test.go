// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package dev

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

type runtimeBoundary struct {
	forbiddenRoots, forbiddenReferences []string
}

func insidePath(path, parent string) bool {
	if canonical, err := filepath.EvalSymlinks(parent); err == nil {
		parent = canonical
	}
	if canonical, err := filepath.EvalSymlinks(path); err == nil {
		path = canonical
	}
	relative, err := filepath.Rel(parent, path)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func (boundary runtimeBoundary) reference(repository, source, reference string) error {
	reference = strings.ReplaceAll(reference, "\\", "/")
	for _, forbidden := range boundary.forbiddenReferences {
		if reference == forbidden || strings.HasPrefix(reference, forbidden+"/") {
			return fmt.Errorf("development dependency in runtime input %s: %s", source, reference)
		}
	}
	// Leading parent components also cover manifest-relative include paths.
	components := strings.Split(strings.TrimPrefix(reference, "/../"), "/")
	for len(components) > 0 && (components[0] == "." || components[0] == "..") {
		components = components[1:]
	}
	for _, forbidden := range boundary.forbiddenRoots {
		local := strings.Join(components, "/")
		if strings.EqualFold(local, forbidden) || strings.HasPrefix(strings.ToLower(local), strings.ToLower(forbidden)+"/") {
			return fmt.Errorf("development asset in runtime input %s: %s", source, reference)
		}
		bases := []string{repository, filepath.Dir(source), filepath.Dir(filepath.Dir(source))}
		for _, base := range bases {
			candidate := reference
			if !filepath.IsAbs(candidate) {
				candidate = filepath.Join(base, filepath.FromSlash(reference))
			}
			if resolved, err := filepath.EvalSymlinks(candidate); err == nil {
				candidate = resolved
			}
			if insidePath(filepath.Clean(candidate), filepath.Join(repository, forbidden)) {
				return fmt.Errorf("runtime dependency resolves into %s: %s: %s", forbidden, source, reference)
			}
		}
	}
	return nil
}

var runtimeQuotedReferences = regexp.MustCompile("\"(?:[^\"\\\\]|\\\\.)*\"|`[^`]*`")

func (boundary runtimeBoundary) source(repository, path string) error {
	if err := boundary.reference(repository, path, path); err != nil {
		return err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var references []string
	extension := filepath.Ext(path)
	if extension == ".json" || extension == ".yaml" || extension == ".yml" {
		decoder := yaml.NewDecoder(bytes.NewReader(data))
		for {
			var document yaml.Node
			if err := decoder.Decode(&document); err != nil {
				if err == io.EOF {
					break
				}
				return err
			}
			pending := []*yaml.Node{&document}
			for len(pending) > 0 {
				node := pending[len(pending)-1]
				pending = pending[:len(pending)-1]
				if node.Kind == yaml.ScalarNode && node.Tag == "!!str" {
					references = append(references, node.Value)
				}
				pending = append(pending, node.Content...)
			}
		}
	} else if extension == ".go" {
		file, err := parser.ParseFile(token.NewFileSet(), path, data, parser.ParseComments)
		if err != nil {
			return err
		}
		ast.Inspect(file, func(node ast.Node) bool {
			if literal, ok := node.(*ast.BasicLit); ok && literal.Kind == token.STRING {
				if value, err := strconv.Unquote(literal.Value); err == nil {
					references = append(references, value)
				}
			}
			return true
		})
		for _, group := range file.Comments {
			for _, comment := range group.List {
				if patterns, ok := strings.CutPrefix(comment.Text, "//go:embed "); ok {
					for _, pattern := range strings.Fields(patterns) {
						references = append(references, strings.Trim(pattern, "\"`"))
					}
				}
			}
		}
	} else {
		for _, quoted := range runtimeQuotedReferences.FindAllString(string(data), -1) {
			value, err := strconv.Unquote(quoted)
			if err != nil {
				value = strings.Trim(quoted, "\"`")
			}
			references = append(references, value)
		}
		for _, forbidden := range boundary.forbiddenReferences {
			if strings.Contains(string(data), forbidden) {
				return fmt.Errorf("development module reference in runtime input %s: %s", path, forbidden)
			}
		}
	}
	for _, reference := range references {
		if err := boundary.reference(repository, path, reference); err != nil {
			return err
		}
	}
	return nil
}

func TestProjectArchitectureRuntimeAssetBoundary(t *testing.T) {
	repository := root(t)
	parts := projectParts(t)
	boundary := runtimeBoundary{}
	var entries, developmentEntries, roots, inputs []string
	assetRoots := 0
	for _, part := range parts {
		if part.Properties["owner"] != projectNamespace+"RuntimeBoundary" {
			continue
		}
		path := part.Properties["name"]
		switch projectKind(part) {
		case "ForbiddenRuntimeRoot":
			boundary.forbiddenRoots = append(boundary.forbiddenRoots, path)
		case "ForbiddenRuntimeReference":
			boundary.forbiddenReferences = append(boundary.forbiddenReferences, path)
		case "RuntimeGoEntry":
			entries = append(entries, path)
		case "DevelopmentGoEntry":
			developmentEntries = append(developmentEntries, path)
			boundary.forbiddenRoots = append(boundary.forbiddenRoots, path)
		case "RuntimeAssetRoot":
			assetRoots++
			roots = append(roots, filepath.Join(repository, path))
		case "RuntimeSourceRoot":
			roots = append(roots, filepath.Join(repository, path))
		case "RuntimeInput":
			inputs = append(inputs, filepath.Join(repository, path))
		default:
			t.Fatalf("unhandled runtime boundary declaration: %s", projectKind(part))
		}
	}
	if len(entries) == 0 || len(boundary.forbiddenRoots) == 0 || len(roots) == 0 || assetRoots == 0 {
		t.Fatal("incomplete SysML runtime boundary")
	}
	classified := map[string]bool{}
	for _, entry := range append(append([]string{}, entries...), developmentEntries...) {
		classified[entry] = true
	}
	for path := range projectLayout(parts, "GoPackage") {
		if strings.HasPrefix(path, "go/cmd/") && !classified[path] {
			t.Fatalf("command has no runtime/development allocation: %s", path)
		}
	}
	for path := range projectLayout(parts, "RustPackage") {
		roots = append(roots, filepath.Join(repository, path, "src"))
		inputs = append(inputs, filepath.Join(repository, path, "Cargo.toml"))
		build := filepath.Join(repository, path, "build.rs")
		if _, err := os.Stat(build); err == nil {
			inputs = append(inputs, build)
		}
	}
	for _, entry := range entries {
		relative, err := filepath.Rel(filepath.Join(repository, "go"), filepath.Join(repository, entry))
		if err != nil {
			t.Fatal(err)
		}
		stream := json.NewDecoder(bytes.NewReader(tool(t, filepath.Join(runtime.GOROOT(), "bin/go"), "-C", "go", "list", "-deps", "-json", "./"+filepath.ToSlash(relative))))
		for {
			var pkg struct {
				Dir, ImportPath                   string
				GoFiles, CgoFiles, IgnoredGoFiles []string
			}
			if err := stream.Decode(&pkg); err != nil {
				if err == io.EOF {
					break
				}
				t.Fatal(err)
			}
			if err := boundary.reference(repository, pkg.Dir, pkg.ImportPath); err != nil {
				t.Fatal(err)
			}
			if insidePath(pkg.Dir, repository) {
				for _, name := range append(append(pkg.GoFiles, pkg.CgoFiles...), pkg.IgnoredGoFiles...) {
					if strings.HasSuffix(name, "_test.go") {
						continue
					}
					inputs = append(inputs, filepath.Join(pkg.Dir, name))
				}
			}
		}
	}
	for _, root := range roots {
		if err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if err := boundary.reference(repository, path, path); err != nil {
				return err
			}
			if !entry.IsDir() {
				switch filepath.Ext(path) {
				case ".rs", ".ss", ".proto", ".json", ".yaml", ".yml":
					inputs = append(inputs, path)
				}
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	for _, input := range inputs {
		if err := boundary.source(repository, input); err != nil {
			t.Fatal(err)
		}
	}
	t.Log("SysML-declared runtime import closure and literal asset references exclude development dependencies")
}

func TestProjectArchitectureRejectsRuntimeDevReferences(t *testing.T) {
	repository := t.TempDir()
	for _, path := range []string{"dev/proofs", "prod/policies", "go/runtime", "crates/demo/src"} {
		if err := os.MkdirAll(filepath.Join(repository, path), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	boundary := runtimeBoundary{[]string{"dev", "go/internal/devrunner"}, []string{"example/go/dev", ":example/dev", "weaver-dev"}}
	for _, path := range []string{"dev/proofs/review.cedar", "prod/policies/review.cedar"} {
		if err := os.WriteFile(filepath.Join(repository, path), []byte("permit(principal,action,resource);"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	cases := []struct{ name, path, content string }{
		{"go-import", "go/runtime/bad.go", "package runtime\nimport _ \"example/go/dev\""},
		{"go-read", "go/runtime/bad.go", "package runtime\nconst schema = \"../../dev/proofs/review.cedar\""},
		{"development-tool-file", "go/runtime/bad.go", "package runtime\nconst helper = \"../../go/internal/devrunner/plan.go\""},
		{"development-command", "go/runtime/bad.go", "package runtime\nconst command = \"weaver-dev\""},
		{"go-embed", "go/runtime/bad.go", "package runtime\n//go:embed ../../dev/proofs/review.cedar\nvar schema string"},
		{"rust-include", "crates/demo/src/bad.rs", "const POLICY: &str = include_str!(\"../../../dev/proofs/review.cedar\");"},
		{"scheme-module", "bad.ss", "(import :example/dev/proof)"},
		{"scheme-path", "bad.ss", "(path-expand \"dev/proofs/review.cedar\")"},
		{"build-input", "Cargo.toml", "[build-dependencies]\nhelper = {path = \"dev/generator\"}"},
		{"runtime-config", "profile.json", "{\"policy_file\":\"dev/proofs/review.cedar\"}"},
		{"yaml-config", "profile.yaml", "policy_file: dev/proofs/review.cedar\n"},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(repository, test.path)
			if err := os.WriteFile(path, []byte(test.content), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := boundary.source(repository, path); err == nil {
				t.Fatal("runtime development dependency accepted")
			}
		})
	}
	alias := filepath.Join(repository, "prod/policies/alias.cedar")
	if err := os.Symlink(filepath.Join(repository, "dev/proofs/review.cedar"), alias); err != nil {
		t.Fatal(err)
	}
	if err := boundary.reference(repository, filepath.Join(repository, "build.rs"), "prod/policies/alias.cedar"); err == nil {
		t.Fatal("prod symlink back into development accepted")
	}
	if err := boundary.reference(repository, filepath.Join(repository, "build.rs"), "prod/policies/review.cedar"); err != nil {
		t.Fatal("owned production artifact refused", err)
	}
	allowed := filepath.Join(repository, "go/runtime/good.go")
	if err := os.WriteFile(allowed, []byte("package runtime\n// dev/proofs is documentation, not an input\nconst policy = \"../../prod/policies/review.cedar\""), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := boundary.source(repository, allowed); err != nil {
		t.Fatal("production path or ordinary Go comment refused", err)
	}
}
