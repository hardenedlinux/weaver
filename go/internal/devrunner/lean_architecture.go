// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
)

func leanArchitectureStage() Stage {
	return Stage{Name: "lean-architecture-environment", Binary: "elan", Args: []string{
		"run", proofToolchain, "lake", "-d", "dev/proofs/cedar", "env", "lean", "--json", "dev/proofs/cedar/ZeroTrustArchitecture.lean",
	}}
}

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
	stage := leanArchitectureStage()
	result := runStage(ctx, root, dir, os.Environ(), stage)
	if result.Status != "PASS" || result.Lean == nil || result.Lean.Environment == nil {
		return result, fmt.Errorf("locked Lean dependency could not export the Gateway contract; no SysML/D2 fallback: %s (%s)", result.Log, result.Error)
	}
	return result, nil
}

func publishArchitecture(ctx context.Context, root string) (string, error) {
	results, err := currentLeanResults(root)
	if err != nil {
		return "", err
	}
	// A source-current policy receipt already includes the locked environment.
	// Reuse that owner once; declaration conflicts remain an error downstream.
	for _, result := range results {
		if result.Name == leanArchitectureStage().Name && result.Status == "PASS" && result.Lean != nil && result.Lean.Environment != nil {
			return publishModelViewsWithEvidence(ctx, root, results)
		}
	}
	imported, err := exportLeanArchitecture(ctx, root)
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
	// The SDK, rather than a D2 filename convention, declares whether the
	// selected views require the imported contract. Final capture independently
	// rechecks sources and still rejects absent or incomplete evidence.
	capture, err := CaptureModelViews(ctx, root)
	if err != nil {
		return "", err
	}
	if capture.requiresLeanEnvironment(selected) {
		imported, err := exportLeanArchitecture(ctx, root)
		if err != nil {
			return "", err
		}
		results = append(results, imported)
	}
	return publishModelViewsWithEvidence(ctx, root, results, selected...)
}

func (capture *ModelViewCapture) requiresLeanEnvironment(selected []string) bool {
	for _, description := range capture.Descriptions {
		if description.LeanEnvironment && slices.Contains(selected, description.File) {
			return true
		}
	}
	return false
}
