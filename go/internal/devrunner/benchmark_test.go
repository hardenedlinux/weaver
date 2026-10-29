package devrunner

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeBenchmarkEstimate(t *testing.T, root, name string) {
	t.Helper()
	path := filepath.Join(root, "target/criterion", name, "new/estimates.json")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"mean":{"point_estimate":1,"confidence_interval":{"lower_bound":1,"upper_bound":1}}}`), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestBenchmarkEvidenceRequiresEveryCase(t *testing.T) {
	for _, omitted := range []string{"", "ledger_publication_atomic_commit", "server_response_encoding/arrow_batch/32"} {
		t.Run("missing="+omitted, func(t *testing.T) {
			root, output := t.TempDir(), t.TempDir()
			for _, name := range rustBenchmarkCases {
				if name != omitted {
					writeBenchmarkEstimate(t, root, name)
				}
			}
			err := collectBenchmarks(root, output, time.Unix(200, 0).UTC().Format(time.RFC3339Nano))
			if omitted != "" {
				if err == nil || !strings.Contains(err.Error(), omitted) {
					t.Fatalf("partial package evidence accepted or unexplained: %v", err)
				}
				if _, err := os.Stat(filepath.Join(output, "benchmark-summary.org")); !os.IsNotExist(err) {
					t.Fatal("incomplete matrix published a successful summary")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(filepath.Join(output, "benchmark-summary.org"))
			if err != nil {
				t.Fatal(err)
			}
			for _, name := range rustBenchmarkCases {
				if !strings.Contains(string(data), "| "+name+" |") {
					t.Fatalf("missing summary row: %s", name)
				}
			}
		})
	}
}

func TestBenchmarkEvidenceRejectsUnmappedCase(t *testing.T) {
	root := t.TempDir()
	writeBenchmarkEstimate(t, root, "contracts_spoofed")
	err := collectBenchmarks(root, t.TempDir(), time.Unix(200, 0).UTC().Format(time.RFC3339Nano))
	if err == nil || !strings.Contains(err.Error(), "unmapped") {
		t.Fatalf("unmapped case accepted: %v", err)
	}
}
