package devrunner

import (
	"maps"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSourceCurrentnessRejectsDifferentExpectedInput(t *testing.T) {
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
	changed := maps.Clone(inputs)
	changed["Cargo.lock"] = "different-source-hash"
	if result := sourceCurrentness(root, t.TempDir(), changed); result.Status != "FAIL" {
		t.Fatal("changed source accepted")
	}
	if result := sourceCurrentness(root, t.TempDir(), inputs); result.Status != "PASS" {
		t.Fatal(result.Error)
	}
}
func TestOldBenchmarkFilesCannotQualifyCurrentRun(t *testing.T) {
	root := t.TempDir()
	for _, group := range []string{"contracts", "policy", "ledger", "execution", "server"} {
		path := filepath.Join(root, "target/criterion", group, "new/estimates.json")
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(`{"mean":{"point_estimate":1,"confidence_interval":{"lower_bound":1,"upper_bound":1}}}`), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, time.Unix(100, 0), time.Unix(100, 0)); err != nil {
			t.Fatal(err)
		}
	}
	if err := collectBenchmarks(root, t.TempDir(), time.Unix(200, 0).UTC().Format(time.RFC3339Nano)); err == nil {
		t.Fatal("stale benchmarks accepted")
	}
}
