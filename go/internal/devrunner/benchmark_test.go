package devrunner

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBenchmarkPackagesRequireExactWorkspaceCoverage(t *testing.T) {
	members := []string{"weaver-contracts", "weaver-governance", "weaver-governance-build", "weaver-policy", "weaver-policy-ffi", "weaver-ledger", "weaver-execution", "weaver-server"}
	if err := ValidateBenchmarkPackages(members); err != nil {
		t.Fatal(err)
	}
	for _, missing := range members {
		t.Run("absent="+missing, func(t *testing.T) {
			var subset []string
			for _, member := range members {
				if member != missing {
					subset = append(subset, member)
				}
			}
			if err := ValidateBenchmarkPackages(subset); err == nil || !strings.Contains(err.Error(), missing) {
				t.Fatalf("orphaned measured owner accepted: %v", err)
			}
		})
	}
	for _, additional := range []string{"weaver-new-member", "weaver-server"} {
		if err := ValidateBenchmarkPackages(append(append([]string{}, members...), additional)); err == nil || !strings.Contains(err.Error(), additional) {
			t.Fatalf("unqualified or duplicate workspace member accepted: %v", err)
		}
	}
}

func TestBenchmarkPlanChecksPackageContractBeforeMeasurement(t *testing.T) {
	stages, err := Stages("bench", "go")
	if err != nil {
		t.Fatal(err)
	}
	checked := false
	for _, stage := range stages {
		if stage.Name == "benchmark-package-contract" {
			checked = true
		}
		if stage.Name == "rust-benchmarks" && !checked {
			t.Fatal("measurement can run without its workspace coverage gate")
		}
	}
	if !checked {
		t.Fatal("benchmark package contract stage missing")
	}
}

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

func TestFinalSendBenchmarkSubsetCannotQualifyWholeWorkspace(t *testing.T) {
	root := t.TempDir()
	for _, name := range storageBenchmarkCases {
		writeBenchmarkEstimate(t, root, name)
	}
	started := time.Unix(200, 0).UTC().Format(time.RFC3339Nano)
	if err := collectBenchmarks(root, t.TempDir(), started, storageBenchmarkCases...); err != nil {
		t.Fatal(err)
	}
	if err := collectBenchmarks(root, t.TempDir(), started); err == nil {
		t.Fatal("selected final-send results qualified unrelated packages")
	}
	for _, selected := range [][]string{{"unowned"}, {storageBenchmarkCases[0], storageBenchmarkCases[0]}} {
		if err := collectBenchmarks(root, t.TempDir(), started, selected...); err == nil {
			t.Fatal("invalid or duplicate selected measurement admitted")
		}
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
