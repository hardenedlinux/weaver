package devrunner

import (
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Reproduce the workflow's evidence exclusions without requiring Git, network
// access, or the archived files to be materialized in the sparse checkout.
func TestSourceInputsWithArchivedEvidenceExcluded(t *testing.T) {
	working, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(working)
	if err != nil {
		t.Fatal(err)
	}
	inputs, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	sparse := t.TempDir()
	for path := range inputs {
		if strings.HasPrefix(path, "dev/proofs/evidence/") || strings.HasPrefix(path, "dev/specs/evidence/") {
			continue
		}
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(path)))
		if err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(sparse, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, body, 0600); err != nil {
			t.Fatal(err)
		}
	}
	actual, err := SourceInputs(sparse)
	if err != nil {
		t.Fatalf("live source inventory requires excluded historical evidence: %v", err)
	}
	if !maps.Equal(inputs, actual) {
		t.Fatal("sparse-checkout live source inventory changed")
	}
}
