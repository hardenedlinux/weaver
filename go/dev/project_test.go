package dev

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/Open-MBEE/OpenSysML/client/opensysml"
)

const projectNamespace = "WeaverProject::"

func projectModel(t *testing.T, ctx context.Context, client opensysml.Client) *opensysml.Model {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(root(t), "dev/sysml/*.sysml"))
	if err != nil || len(paths) == 0 {
		t.Fatal("development SysML models missing", err)
	}
	paths = append([]string{filepath.Join(root(t), "Project.sysml")}, paths...)
	model, err := client.ParseFiles(ctx, paths, opensysml.WithStrictConformance())
	if err != nil {
		t.Fatal(err)
	}
	if !model.OK() {
		t.Fatalf("linked Project/SysML model failed strict SDK analysis: %v", model.Errors())
	}
	return model
}

func projectParts(t *testing.T) []opensysml.QueryElement {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client, err := opensysml.New(opensysml.WithCacheSize(1))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	model := projectModel(t, ctx, client)
	parts, err := client.Query(ctx, model, opensysml.Query{Scope: []string{"WeaverProject"}, Select: []string{"name", "owner", "type"}, Where: opensysml.Equals("@type", "PartUsage")})
	if err != nil {
		t.Fatal(err)
	}
	if len(parts) == 0 {
		t.Fatal("empty project architecture")
	}
	return parts
}

func projectKind(part opensysml.QueryElement) string {
	return strings.TrimPrefix(part.Properties["type"], projectNamespace)
}

func projectLayout(parts []opensysml.QueryElement, kind string) map[string]opensysml.QueryElement {
	result := map[string]opensysml.QueryElement{}
	for _, part := range parts {
		if part.Properties["owner"] == projectNamespace+"Layout" && projectKind(part) == kind {
			result[part.Properties["name"]] = part
		}
	}
	return result
}

func projectRustLayers(t *testing.T) map[string]string {
	t.Helper()
	parts := projectParts(t)
	result := map[string]string{}
	for path, part := range projectLayout(parts, "RustPackage") {
		var dependencies []string
		for _, child := range parts {
			if child.Properties["owner"] == part.ID && projectKind(child) == "RuntimeDependency" {
				dependencies = append(dependencies, child.Properties["name"])
			}
		}
		result[path] = strings.Join(dependencies, ",")
	}
	return result
}

func projectPath(root, path, kind string) error {
	if !filepath.IsLocal(path) || strings.Contains(path, "\\") {
		return fmt.Errorf("nonlocal project path: %q", path)
	}
	info, err := os.Lstat(filepath.Join(root, path))
	if kind == "Absent" {
		if !os.IsNotExist(err) {
			return fmt.Errorf("retired layout path exists: %s", path)
		}
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("project owner is a symlink: %s", path)
	}
	if kind == "File" {
		if !info.Mode().IsRegular() {
			return fmt.Errorf("project source is not a regular file: %s", path)
		}
	} else if !info.IsDir() {
		return fmt.Errorf("project owner is not a directory: %s", path)
	}
	return nil
}

func projectChildren(root, parent string, wanted map[string]opensysml.QueryElement) error {
	entries, err := os.ReadDir(filepath.Join(root, parent))
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			path := filepath.ToSlash(filepath.Join(parent, entry.Name()))
			if _, ok := wanted[path]; !ok {
				return fmt.Errorf("unmodeled project owner: %s", path)
			}
		}
	}
	return nil
}

func TestProjectArchitecture(t *testing.T) {
	repository := root(t)
	parts := projectParts(t)
	rootOwners := projectLayout(parts, "Directory")
	prohibited := map[string]bool{}
	for _, part := range parts {
		if part.Properties["owner"] == projectNamespace+"SourcePolicy" && projectKind(part) == "ProhibitedExtension" {
			prohibited[part.Properties["name"]] = true
		}
	}
	for _, tracked := range strings.Split(string(tool(t, "git", "ls-files", "-z")), "\x00") {
		if prohibited[filepath.Ext(tracked)] {
			t.Fatalf("retired source language remains tracked: %s", tracked)
		}
		if separator := strings.IndexByte(tracked, '/'); separator >= 0 {
			if _, ok := rootOwners[tracked[:separator]]; !ok {
				t.Fatalf("unmodeled versioned root owner: %s", tracked)
			}
		}
	}
	for _, part := range parts {
		if part.Properties["owner"] != projectNamespace+"Layout" {
			continue
		}
		path, kind := part.Properties["name"], projectKind(part)
		if kind == "IgnoredDirectory" {
			tool(t, "git", "check-ignore", "--quiet", path+"/project-probe")
			if files := tool(t, "git", "ls-files", "--", path); len(files) != 0 {
				t.Fatalf("generated artifacts tracked under %s", path)
			}
			continue
		}
		switch kind {
		case "Directory", "File", "RustPackage", "SchemeModule", "GoPackage", "Absent":
		default:
			t.Fatalf("unknown layout kind %s", kind)
		}
		if err := projectPath(repository, path, kind); err != nil {
			t.Fatal(err)
		}
		if kind == "RustPackage" || kind == "SchemeModule" {
			for _, member := range parts {
				if member.Properties["owner"] == projectNamespace+kind {
					if err := projectPath(repository, filepath.Join(path, member.Properties["name"]), projectKind(member)); err != nil {
						t.Fatal(err)
					}
				}
			}
		}
	}
	for kind, parent := range map[string]string{"RustPackage": "crates", "SchemeModule": "scheme"} {
		owners := projectLayout(parts, kind)
		if len(owners) == 0 {
			t.Fatalf("missing modeled %s owners", kind)
		}
		if err := projectChildren(repository, parent, owners); err != nil {
			t.Fatal(err)
		}
	}
	assets := projectLayout(parts, "File")
	if err := filepath.WalkDir(filepath.Join(repository, "prod"), func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		relative, err := filepath.Rel(repository, path)
		if err != nil {
			return err
		}
		if _, ok := assets[filepath.ToSlash(relative)]; !ok {
			return fmt.Errorf("unmodeled production asset: %s", relative)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	goOwners := projectLayout(parts, "GoPackage")
	for _, directory := range strings.Split(strings.TrimSpace(string(tool(t, filepath.Join(runtime.GOROOT(), "bin/go"), "-C", "go", "list", "-f", "{{.Dir}}", "./..."))), "\n") {
		relative, err := filepath.Rel(repository, directory)
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.ToSlash(relative)
		if _, ok := goOwners[path]; !ok {
			t.Fatalf("unmodeled Go package %s", path)
		}
		delete(goOwners, path)
	}
	if len(goOwners) != 0 {
		t.Fatalf("modeled Go packages absent from workspace: %v", goOwners)
	}
	t.Log("Root Project.sysml controls package, dependency, asset and cache ownership")
}

func TestProjectArchitectureRequiresLinkedDomainModels(t *testing.T) {
	client, err := opensysml.New(opensysml.WithCacheSize(1))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	model, err := client.ParseFile(context.Background(), filepath.Join(root(t), "Project.sysml"), opensysml.WithStrictConformance())
	if err != nil {
		t.Fatal(err)
	}
	if model.OK() {
		t.Fatal("project allocation accepted without its referenced domain models")
	}
}

func TestProjectArchitectureRejectsUnmodeledAndNonlocalOwners(t *testing.T) {
	repository := t.TempDir()
	if err := os.MkdirAll(filepath.Join(repository, "crates/unmodeled"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := projectChildren(repository, "crates", map[string]opensysml.QueryElement{}); err == nil {
		t.Fatal("unmodeled Rust owner accepted")
	}
	if err := projectPath(repository, "../outside", "File"); err == nil {
		t.Fatal("nonlocal owner accepted")
	}
	if err := projectPath(repository, "crates", "Absent"); err == nil {
		t.Fatal("retired owner accepted")
	}
}
