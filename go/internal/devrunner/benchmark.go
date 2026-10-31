package devrunner

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"math"
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
	"contracts_publication_review_commitment",
	"contracts_source_rotation_commitment",
	"contracts_profile_commitment",
	"contracts_profile_request_validation/128",
	"contracts_profile_request_validation/16384",
	"contracts_profile_request_validation/524288",
	"policy_typed_schema_validation",
	"policy_warm_compilation_current_decision",
	"policy_compilation_cache_churn",
	"policy_materialized_json_schema_validation",
	"policy_spec_schema_bound_candidate_replay",
	"policy-ffi_typed_preflight",
	"ledger_fresh_admission",
	"ledger_consume_and_dispatch_burn",
	"ledger_idempotent_admission",
	"ledger_publication_atomic_commit",
	"ledger_publication_stage_and_decide",
	"ledger_reviewed_publication_register_and_commit",
	"ledger_spec_replay_register_and_commit",
	"ledger_source_key_handoff",
	"ledger_source_authenticated_publication",
	"ledger_publication_exact_replay",
	"ledger_publication_historical_lookup",
	"ledger_profile_task_registration",
	"ledger_profile_task_replay/1",
	"ledger_profile_task_replay/256",
	"execution_https_guarded_sse_three_events",
	"server_response_encoding/protobuf_frames/1",
	"server_response_encoding/protobuf_frames/32",
	"server_response_encoding/arrow_batch/1",
	"server_response_encoding/arrow_batch/32",
	"server_source_certificate_spki_identity",
}

// Criterion sanitizes the package/group separator to an underscore on disk.
func benchmarkPackage(name string) (string, error) {
	for _, member := range []string{"contracts", "policy", "policy-ffi", "ledger", "execution", "server"} {
		if strings.HasPrefix(name, member+"_") {
			return "weaver-" + member, nil
		}
	}
	return "", fmt.Errorf("benchmark has no package owner: %s", name)
}

// ValidateBenchmarkPackages joins the measured inventory to Cargo's actual members.
// Neither a benchmark in another package nor a target without measured cases qualifies.
func ValidateBenchmarkPackages(members []string) error {
	owners := map[string]bool{}
	cases := map[string]bool{}
	for _, name := range rustBenchmarkCases {
		owner, err := benchmarkPackage(name)
		if err != nil {
			return err
		}
		if cases[name] {
			return fmt.Errorf("duplicate benchmark case: %s", name)
		}
		cases[name], owners[owner] = true, true
	}
	seen := map[string]bool{}
	for _, member := range members {
		if seen[member] {
			return fmt.Errorf("duplicate workspace member: %s", member)
		}
		seen[member] = true
		if !owners[member] {
			return fmt.Errorf("workspace member has no measured benchmark cases: %s", member)
		}
	}
	for owner := range owners {
		if !seen[owner] {
			return fmt.Errorf("benchmark owner is absent from workspace: %s", owner)
		}
	}
	return nil
}

// An estimate alone is insufficient: retain the original thirty measured samples.
func benchmarkSamples(path string, begin time.Time) (int, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	if info.ModTime().Before(begin) {
		return 0, fmt.Errorf("stale benchmark samples: %s", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	var sample struct {
		Iterations []float64 `json:"iters"`
		Times      []float64 `json:"times"`
	}
	if err := json.Unmarshal(data, &sample); err != nil {
		return 0, err
	}
	if len(sample.Iterations) != 30 || len(sample.Times) != 30 {
		return 0, fmt.Errorf("benchmark requires thirty paired samples: %s", path)
	}
	for i, iterations := range sample.Iterations {
		elapsed := sample.Times[i]
		if !positiveFinite(iterations) || math.Trunc(iterations) != iterations || !positiveFinite(elapsed) {
			return 0, fmt.Errorf("invalid benchmark sample %d: %s", i, path)
		}
	}
	return len(sample.Times), nil
}

func positiveFinite(value float64) bool {
	return value > 0 && !math.IsInf(value, 0) && !math.IsNaN(value)
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
			if !positiveFinite(mean.Point) || !positiveFinite(mean.Interval.Lower) ||
				!positiveFinite(mean.Interval.Upper) || mean.Interval.Lower > mean.Point || mean.Point > mean.Interval.Upper {
				return fmt.Errorf("invalid benchmark mean or confidence bounds: %s", name)
			}
			owner, err := benchmarkPackage(name)
			if err != nil {
				return err
			}
			samples, err := benchmarkSamples(filepath.Join(filepath.Dir(path), "sample.json"), begin)
			if err != nil {
				return fmt.Errorf("%s: %w", name, err)
			}
			measured[name] = true
			rows = append(rows, fmt.Sprintf("| %s | %s | %d | %.3f | %.3f | %.3f |", owner, name, samples, mean.Point, mean.Interval.Lower, mean.Interval.Upper))
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
	report := "#+TITLE: Native Rust Benchmark Baseline\n#+LANGUAGE: en\n\n* Scope\nLocal empirical baseline, not a throughput guarantee. Values are nanoseconds per measured iteration. Compiler and client metadata are in the latest structured result. Go RPC client allocations are not Rust allocations. Raw stage logs are temporary and cleaned after execution.\n\n| Package | Benchmark | Samples | Mean ns | Lower confidence bound ns | Upper confidence bound ns |\n|---------+-----------+---------+---------+---------------------------+---------------------------|\n" + strings.Join(rows, "\n") + "\n"
	return os.WriteFile(filepath.Join(directory, "benchmark-summary.org"), []byte(report), 0600)
}
