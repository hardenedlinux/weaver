package devrunner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

// Use the existing Lake dependency closure. Never silently substitute the
// ignored upstream research checkout for the project's locked dependency.
func exportLeanArchitecture(ctx context.Context, root string) (Result, error) {
	dir := filepath.Join(root, ".cache/d2/lean")
	if err := os.MkdirAll(dir, 0755); err != nil {
		return Result{}, err
	}
	dir, err := os.MkdirTemp(dir, "environment-")
	if err != nil {
		return Result{}, err
	}
	stage := Stage{Name: "lean-architecture-environment", Binary: "elan", Args: []string{
		"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "env", "lean", "--json", "dev/proofs/cedar/ZeroTrustArchitecture.lean",
	}}
	result := runStage(ctx, root, dir, os.Environ(), stage)
	if result.Status != "PASS" || result.Lean == nil || result.Lean.Environment == nil {
		return result, fmt.Errorf("locked Lean dependency could not export the Gateway contract; no SysML/D2 fallback: %s (%s)", result.Log, result.Error)
	}
	return result, nil
}

func publishArchitecture(ctx context.Context, root string) (string, error) {
	imported, err := exportLeanArchitecture(ctx, root)
	if err != nil {
		return "", err
	}
	results, err := currentLeanResults(root)
	if err != nil {
		return "", err
	}
	return publishModelViewsWithEvidence(ctx, root, append(results, imported))
}

// Selected local views compile their actual Lean owners without importing an
// unrelated SPEC environment. Imported-environment views still fail closed if
// their declarations are unavailable; this is no fallback for those views.
func publishSelectedArchitecture(ctx context.Context, root string, selected []string) (string, error) {
	if len(selected) == 0 {
		return publishArchitecture(ctx, root)
	}
	directory := filepath.Join(root, ".cache/d2/lean")
	if err := os.MkdirAll(directory, 0755); err != nil {
		return "", err
	}
	directory, err := os.MkdirTemp(directory, "selected-")
	if err != nil {
		return "", err
	}
	var results []Result
	for _, stage := range Plan("go") {
		if leanSource(stage) == "" || len(stage.Args) != 5 {
			continue
		}
		result := runStage(ctx, root, directory, os.Environ(), stage)
		if result.Status != "PASS" {
			return "", fmt.Errorf("selected-view proof owner failed: %s: %s", result.Log, result.Error)
		}
		results = append(results, result)
	}
	return publishModelViewsWithEvidence(ctx, root, results, selected...)
}
