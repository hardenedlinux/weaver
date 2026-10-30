package devrunner

import (
	"encoding/json"
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
	if result := schemeSourceCurrentness(t.TempDir(), "after"); result.Status != "FAIL" {
		t.Fatal("changed linked source accepted")
	}
}
