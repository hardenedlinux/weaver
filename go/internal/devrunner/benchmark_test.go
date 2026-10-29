package devrunner

import (
	"encoding/json"
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
	samples := strings.TrimSuffix(path, "estimates.json") + "sample.json"
	values := strings.TrimSuffix(strings.Repeat("1,", 30), ",")
	if err := os.WriteFile(samples, []byte(`{"iters":[`+values+`],"times":[`+values+`]}`), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestBenchmarkEvidenceRejectsInvalidMeasurements(t *testing.T) {
	for _, fault := range []string{"missing-samples", "stale-samples", "stale-estimate", "short-samples", "mismatched-samples", "zero-time", "fractional-iterations", "negative-iterations", "missing-mean", "zero-mean", "reversed-bounds"} {
		t.Run(fault, func(t *testing.T) {
			root, output := t.TempDir(), t.TempDir()
			for _, name := range rustBenchmarkCases {
				writeBenchmarkEstimate(t, root, name)
			}
			path := filepath.Join(root, "target/criterion", rustBenchmarkCases[0], "new")
			samplePath := filepath.Join(path, "sample.json")
			var err error
			switch fault {
			case "missing-samples":
				err = os.Remove(samplePath)
			case "stale-samples":
				err = os.Chtimes(samplePath, time.Unix(100, 0), time.Unix(100, 0))
			case "stale-estimate":
				err = os.Chtimes(filepath.Join(path, "estimates.json"), time.Unix(100, 0), time.Unix(100, 0))
			case "missing-mean", "zero-mean", "reversed-bounds":
				value := `{}`
				if fault == "zero-mean" {
					value = `{"mean":{"point_estimate":0,"confidence_interval":{"lower_bound":1,"upper_bound":2}}}`
				} else if fault == "reversed-bounds" {
					value = `{"mean":{"point_estimate":1,"confidence_interval":{"lower_bound":2,"upper_bound":1}}}`
				}
				err = os.WriteFile(filepath.Join(path, "estimates.json"), []byte(value), 0600)
			default:
				iters, times := make([]float64, 30), make([]float64, 30)
				for i := range iters {
					iters[i], times[i] = 1, 1
				}
				switch fault {
				case "short-samples":
					iters, times = iters[:29], times[:29]
				case "mismatched-samples":
					times = times[:29]
				case "zero-time":
					times[0] = 0
				case "fractional-iterations":
					iters[0] = 0.5
				case "negative-iterations":
					iters[0] = -1
				}
				data, marshalErr := json.Marshal(map[string][]float64{"iters": iters, "times": times})
				if marshalErr != nil {
					t.Fatal(marshalErr)
				}
				err = os.WriteFile(samplePath, data, 0600)
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := collectBenchmarks(root, output, time.Unix(200, 0).UTC().Format(time.RFC3339Nano)); err == nil {
				t.Fatal("invalid measured evidence accepted")
			}
			if _, err := os.Stat(filepath.Join(output, "benchmark-summary.org")); !os.IsNotExist(err) {
				t.Fatal("invalid measurements published a successful summary")
			}
		})
	}
}

func TestBenchmarkEvidenceRequiresEveryCase(t *testing.T) {
	for _, omitted := range append([]string{""}, rustBenchmarkCases...) {
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
