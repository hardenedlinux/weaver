package devrunner

import (
	"encoding/json"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPooRevisionFollowsInheritedCoreDeclaration(t *testing.T) {
	directory := t.TempDir()
	file := filepath.Join(directory, "gerbil.pkg")
	wanted := strings.Repeat("a", 40)
	for _, data := range []string{`(depend: ("github.com/tao3k/gerbil-poo@` + wanted + `"))`, `(depend: ())`, `(depend: ("github.com/tao3k/gerbil-poo@` + wanted + `" "github.com/tao3k/gerbil-poo@` + strings.Repeat("b", 40) + `"))`} {
		if err := os.WriteFile(file, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		actual, err := DeclaredPooRevision(directory)
		if strings.Count(data, "gerbil-poo@") == 1 {
			if err != nil || actual != wanted {
				t.Fatal("inherited exact revision lost")
			}
		} else if err == nil {
			t.Fatal("missing or ambiguous inherited revision admitted")
		}
	}
}

func TestLinkedSchemeCurrentnessRejectsSourceChange(t *testing.T) {
	source := t.TempDir()
	for _, name := range []string{"core", "modules"} {
		if err := os.Mkdir(filepath.Join(source, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	file := filepath.Join(source, "modules", "governor.ss")
	if err := os.WriteFile(file, []byte("(export native-governor)"), 0600); err != nil {
		t.Fatal(err)
	}
	hashes, err := schemeSourceHashes(source, "")
	if err != nil {
		t.Fatal(err)
	}
	receipt := filepath.Join(t.TempDir(), "environment.json")
	data, _ := json.Marshal(map[string]any{"source_root": source, "source_hashes": hashes})
	if err = os.WriteFile(receipt, data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WEAVER_SCHEME_LINK_RECEIPT", receipt)
	if result := schemeSourceCurrentness(t.TempDir(), "before"); result.Status != "PASS" {
		t.Fatal(result)
	}
	if err = os.WriteFile(file, []byte("(export changed-governor)"), 0600); err != nil {
		t.Fatal(err)
	}
	if result := schemeSourceCurrentness(t.TempDir(), "after"); result.Status != "FAIL" || !strings.Contains(result.Error, "modules/governor.ss") {
		t.Fatal("changed linked source accepted")
	}
}

func TestLinkedSchemeAliasesIncludePooRoot(t *testing.T) {
	source, poo, links := t.TempDir(), t.TempDir(), t.TempDir()
	for _, name := range []string{"modules", "core"} {
		if err := os.Mkdir(filepath.Join(source, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(poo, "object.ss"), []byte("(export object)"), 0600); err != nil {
		t.Fatal(err)
	}
	for name, target := range map[string]string{"source": source, "poo": poo} {
		if err := os.Symlink(target, filepath.Join(links, name)); err != nil {
			t.Fatal(err)
		}
	}
	direct, err := schemeSourceHashes(source, poo)
	if err != nil {
		t.Fatal(err)
	}
	aliased, err := schemeSourceHashes(filepath.Join(links, "source"), filepath.Join(links, "poo"))
	if err != nil || !maps.Equal(direct, aliased) || aliased["gerbil-poo/object.ss"] == "" {
		t.Fatalf("symlink omitted inherited POO source: %v %v", aliased, err)
	}
}

func TestSingleGoModuleRootNeedsNoWorkspace(t *testing.T) {
	root := t.TempDir()
	module := filepath.Join(root, "go")
	if err := os.MkdirAll(filepath.Join(module, "cmd"), 0700); err != nil {
		t.Fatal(err)
	}
	for path, data := range map[string]string{"Cargo.toml": "[workspace]\n", "go/go.mod": "module example.test/control\n"} {
		if err := os.WriteFile(filepath.Join(root, path), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	actual, err := FindRoot(filepath.Join(module, "cmd"))
	if err != nil || actual != root {
		t.Fatalf("single-module project root: %q %v", actual, err)
	}
}
