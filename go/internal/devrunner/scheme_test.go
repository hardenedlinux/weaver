package devrunner

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

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
