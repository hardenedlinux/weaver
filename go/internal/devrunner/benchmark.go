package devrunner

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// Every timed case must produce fresh evidence; one case cannot qualify its package.
var rustBenchmarkCases = []string{
	"contracts_provider_commitment/128",
	"contracts_provider_commitment/16384",
	"contracts_provider_commitment/524288",
	"contracts_publication_commitment",
	"policy_typed_schema_validation",
	"policy_warm_compilation_current_decision",
	"policy_compilation_cache_churn",
	"ledger_fresh_admission",
	"ledger_consume_and_dispatch_burn",
	"ledger_idempotent_admission",
	"ledger_publication_atomic_commit",
	"ledger_publication_exact_replay",
	"ledger_publication_historical_lookup",
	"execution_https_guarded_sse_three_events",
	"server_response_encoding/protobuf_frames/1",
	"server_response_encoding/protobuf_frames/32",
	"server_response_encoding/arrow_batch/1",
	"server_response_encoding/arrow_batch/32",
}

// Copy only structured Criterion data; raw stage logs retain Go/Rust environment receipts.
func collectBenchmarks(root, directory, started string) error {
	begin, err := time.Parse(time.RFC3339Nano, started)
	if err != nil {
		return err
	}
	source := filepath.Join(root, "target/criterion")
	measured := map[string]bool{}
	rows := []string{}
	err = filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		if filepath.Ext(path) != ".json" && filepath.Ext(path) != ".csv" {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.ModTime().Before(begin) {
			return nil
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		bytes, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		target := filepath.Join(directory, "criterion", relative)
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(target, bytes, 0600); err != nil {
			return err
		}
		if strings.HasSuffix(filepath.ToSlash(relative), "/new/estimates.json") {
			// Criterion names confidence bounds explicitly.
			var value map[string]json.RawMessage
			if err := json.Unmarshal(bytes, &value); err != nil {
				return err
			}
			var mean struct {
				Point    float64 `json:"point_estimate"`
				Interval struct {
					Lower float64 `json:"lower_bound"`
					Upper float64 `json:"upper_bound"`
				} `json:"confidence_interval"`
			}
			if err := json.Unmarshal(value["mean"], &mean); err != nil {
				return err
			}
			name := strings.TrimSuffix(filepath.ToSlash(relative), "/new/estimates.json")
			if !slices.Contains(rustBenchmarkCases, name) {
				return fmt.Errorf("unmapped Rust benchmark case: %s", name)
			}
			measured[name] = true
			rows = append(rows, fmt.Sprintf("| %s | %.3f | %.3f | %.3f |", name, mean.Point, mean.Interval.Lower, mean.Interval.Upper))
		}
		return nil
	})
	if err != nil {
		return err
	}
	for _, name := range rustBenchmarkCases {
		if !measured[name] {
			return fmt.Errorf("missing fresh Rust benchmark case: %s", name)
		}
	}
	slices.Sort(rows)
	report := "#+TITLE: Native Rust Benchmark Baseline\n#+LANGUAGE: en\n\n* Scope\nLocal empirical baseline, not a throughput guarantee. Values are nanoseconds per measured iteration. CPU, compiler and client environment are in the adjacent stage logs. Go RPC client allocations are not Rust allocations.\n\n| Benchmark | Mean ns | Lower confidence bound ns | Upper confidence bound ns |\n|-----------+---------+---------------------------+---------------------------|\n" + strings.Join(rows, "\n") + "\n"
	return os.WriteFile(filepath.Join(directory, "benchmark-summary.org"), []byte(report), 0600)
}
