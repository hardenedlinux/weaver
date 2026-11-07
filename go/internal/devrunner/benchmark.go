// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

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
var storageBenchmarkCases = []string{"ledger/final_family_pair/wal", "ledger/final_family_pair/mvcc-serial", "ledger/final_family_pair/mvcc-parallel", "ledger/final_family_pair/mvcc-shared-budget", "ledger/final_family_pair/mvcc-shared-history", "ledger/task_origin_registration/fresh", "ledger/task_origin_registration/receipt-replay", "ledger/task_origin_registration/rebind-rejected"}

var providerReleaseBenchmarkCases = []string{
	"ledger/provider_release/trusted-host/1",
	"ledger/provider_release/trusted-host/8",
	"ledger/provider_release/trusted-host/32",
	"ledger/provider_release/reviewed/1",
	"ledger/provider_release/reviewed/8",
	"ledger/provider_release/reviewed/32",
}

var rustBenchmarkCases = slices.Concat([]string{
	"telemetry/local/record",
	"telemetry/local/snapshot",
	"ledger/task_origin_registration/fresh",
	"ledger/task_origin_registration/receipt-replay",
	"ledger/task_origin_registration/rebind-rejected",
	"governance/owned_source_validate",
	"governance/original_source_capture_and_bind",
	"governance/source_lane_roundtrip",
	"governance/producer_catalog_roundtrip/1",
	"governance/producer_catalog_roundtrip/64",
	"governance-build/stage_request",
	"contracts/provider_commitment/128",
	"contracts/provider_commitment/16384",
	"contracts/provider_commitment/524288",
	"contracts/publication_commitment",
	"contracts/publication_review_commitment",
	"contracts/source_rotation_commitment",
	"contracts/profile_commitment",
	"contracts/profile_request_validation/128",
	"contracts/profile_request_validation/16384",
	"contracts/profile_request_validation/524288",
	"policy/typed_schema_validation",
	"policy/context_json_local",
	"policy/context_literal_local",
	"policy/context_json_shared",
	"policy/context_literal_shared",
	"policy/warm_compilation_current_decision",
	"policy/compilation_cache_churn",
	"policy/materialized_json_schema_validation",
	"policy/spec_schema_bound_candidate_replay",
	"policy/spec_parent_bound_revision_replay",
	"policy-ffi/typed_preflight",
	"policy-ffi/document_and_aggregate_preflight",
	"ledger/fresh_admission",
	"ledger/concurrent_family_pair/wal",
	"ledger/concurrent_family_pair/mvcc",
	"ledger/final_family_pair/wal",
	"ledger/final_family_pair/mvcc-serial",
	"ledger/final_family_pair/mvcc-parallel",
	"ledger/final_family_pair/mvcc-shared-budget",
	"ledger/final_family_pair/mvcc-shared-history",
	"ledger/consume_and_dispatch_burn",
	"ledger/shared_exposure_dispatch/1",
	"ledger/shared_exposure_dispatch/8",
	"ledger/shared_exposure_dispatch/64",
	"ledger/stream_manifest_guard/1",
	"ledger/stream_manifest_guard/8",
	"ledger/stream_manifest_guard/64",
	"ledger/range_tail_guard/0",
	"ledger/range_tail_guard/8",
	"ledger/range_tail_guard/64",
	"ledger/original_reservation_bytes/1/128",
	"ledger/original_reservation_bytes/8/128",
	"ledger/original_reservation_bytes/64/128",
	"ledger/original_reservation_bytes/1/16384",
	"ledger/original_reservation_bytes/8/16384",
	"ledger/original_reservation_bytes/64/16384",
	"ledger/original_reservation_bytes/1/524288",
	"ledger/idempotent_admission",
	"ledger/publication_atomic_commit",
	"ledger/publication_stage_and_decide",
	"ledger/reviewed_publication_register_and_commit",
	"ledger/spec_replay_register_and_commit",
	"ledger/spec_parent_bound_revision_registration",
	"ledger/source_key_handoff",
	"ledger/source_authenticated_publication",
	"ledger/source_empty_store_enrollment/0",
	"ledger/source_empty_store_enrollment/32",
	"ledger/publication_exact_replay",
	"ledger/publication_historical_lookup",
	"ledger/profile_task_registration",
	"ledger/profile_task_replay/1",
	"ledger/profile_task_replay/256",
	"broker/https_guarded_sse_three_events",
	"broker/anthropic_sse_64_deltas",
	"broker/anthropic_buffered_sse_64_deltas",
	"broker/wif_cached_token",
	"server/encoding_guard_hold/inside",
	"server/encoding_guard_hold/outside",
	"server/response_encoding/protobuf_frames/1",
	"server/response_encoding/protobuf_frames/32",
	"server/response_encoding/arrow_batch/1",
	"server/response_encoding/arrow_batch/32",
	"server/source_certificate_spki_identity",
}, providerReleaseBenchmarkCases)

// Each Criterion ID starts with the declared Cargo package owner.
func benchmarkPackage(name string) (string, error) {
	for _, member := range []string{"contracts", "governance", "governance-build", "policy", "policy-ffi", "ledger", "broker", "server", "telemetry"} {
		if strings.HasPrefix(name, member+"/") {
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

func criterionBenchmarkID(directory, relative string, begin time.Time) (string, error) {
	path := filepath.Join(directory, "benchmark.json")
	info, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.ModTime().Before(begin) {
		return "", fmt.Errorf("stale or nonregular benchmark identity: %s", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	var identity struct {
		FullID    string `json:"full_id"`
		Directory string `json:"directory_name"`
	}
	if err := json.Unmarshal(data, &identity); err != nil {
		return "", err
	}
	if identity.FullID == "" || identity.Directory != relative {
		return "", fmt.Errorf("benchmark identity does not match Criterion directory: %s", relative)
	}
	return identity.FullID, nil
}

func collectBenchmarks(targetDirectory, directory, started string, selected ...string) error {
	expected := rustBenchmarkCases
	if len(selected) != 0 {
		seen := map[string]bool{}
		for _, name := range selected {
			if !slices.Contains(rustBenchmarkCases, name) || seen[name] {
				return fmt.Errorf("invalid selected benchmark: %s", name)
			}
			seen[name] = true
		}
		expected = selected
	}
	begin, err := time.Parse(time.RFC3339Nano, started)
	if err != nil {
		return err
	}
	source := filepath.Join(targetDirectory, "criterion")
	measured := map[string]bool{}
	rows := []string{}
	err = filepath.WalkDir(source, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Name() != "estimates.json" || filepath.Base(filepath.Dir(path)) != "new" {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.ModTime().Before(begin) {
			return nil
		}
		directory := filepath.Dir(path)
		relative, err := filepath.Rel(source, filepath.Dir(directory))
		if err != nil {
			return err
		}
		name, err := criterionBenchmarkID(directory, filepath.ToSlash(relative), begin)
		if err != nil {
			return err
		}
		if len(selected) != 0 && !slices.Contains(expected, name) {
			return nil
		}
		if measured[name] {
			return fmt.Errorf("duplicate fresh Rust benchmark case: %s", name)
		}
		if !slices.Contains(rustBenchmarkCases, name) {
			return fmt.Errorf("unmapped Rust benchmark case: %s", name)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		// Criterion names confidence bounds explicitly.
		var value map[string]json.RawMessage
		if err := json.Unmarshal(data, &value); err != nil {
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
		if !positiveFinite(mean.Point) || !positiveFinite(mean.Interval.Lower) ||
			!positiveFinite(mean.Interval.Upper) || mean.Interval.Lower > mean.Point || mean.Interval.Upper < mean.Point {
			return fmt.Errorf("invalid benchmark mean or confidence bounds: %s", name)
		}
		owner, err := benchmarkPackage(name)
		if err != nil {
			return err
		}
		samples, err := benchmarkSamples(filepath.Join(directory, "sample.json"), begin)
		if err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
		measured[name] = true
		rows = append(rows, fmt.Sprintf("| %s | %s | %d | %.3f | %.3f | %.3f |", owner, name, samples, mean.Point, mean.Interval.Lower, mean.Interval.Upper))
		return nil
	})
	if err != nil {
		return err
	}
	for _, name := range expected {
		if !measured[name] {
			return fmt.Errorf("missing fresh Rust benchmark case: %s", name)
		}
	}
	slices.Sort(rows)
	report := "#+TITLE: Native Rust Benchmark Baseline\n#+LANGUAGE: en\n\n* Scope\nLocal empirical baseline, not a throughput guarantee. Values are nanoseconds per measured iteration. Compiler and client metadata are in the latest structured result. Go RPC client allocations are not Rust allocations. Raw stage logs are temporary and cleaned after execution.\n\n| Package | Benchmark | Samples | Mean ns | Lower confidence bound ns | Upper confidence bound ns |\n|---------+-----------+---------+---------+---------------------------+---------------------------|\n" + strings.Join(rows, "\n") + "\n"
	return os.WriteFile(filepath.Join(directory, "benchmark-summary.org"), []byte(report), 0600)
}
