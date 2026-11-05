// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"fmt"
	"path/filepath"
	"strings"
)

func validateLeanEnvironment(environment *LeanEnvironment) error {
	if environment.Schema != "weaver.lean.environment.v1" || len(environment.Declarations) == 0 {
		return fmt.Errorf("unsupported or empty Lean environment")
	}
	seen := map[string]bool{}
	for _, declaration := range environment.Declarations {
		if !strings.HasPrefix(declaration.Name, "CedarPooSpec.") || declaration.Type == "" || seen[declaration.Name] {
			return fmt.Errorf("invalid or duplicate imported Lean declaration: %s", declaration.Name)
		}
		seen[declaration.Name] = true
		fields := map[string]bool{}
		for _, field := range declaration.Fields {
			if field.Name == "" || field.Type == "" || fields[field.Name] {
				return fmt.Errorf("invalid or duplicate Lean field: %s.%s", declaration.Name, field.Name)
			}
			fields[field.Name] = true
		}
	}
	return nil
}

func validateLeanAllocation(caption ModelCaption, contract LeanContract) error {
	if len(caption.LeanFields) == 0 {
		return fmt.Errorf("architecture allocation lacks imported conditions: %s", caption.ID)
	}
	seen := map[string]bool{}
	for _, selected := range caption.LeanFields {
		found := false
		for _, field := range contract.Fields {
			if field.Name == selected {
				found = true
				break
			}
		}
		if !found || seen[selected] {
			return fmt.Errorf("invalid architecture allocation: %s -> %s.%s", caption.ID, contract.Name, selected)
		}
		seen[selected] = true
	}
	for _, field := range contract.Fields {
		if field.Condition && !seen[field.Name] {
			return fmt.Errorf("architecture allocation omits imported condition: %s -> %s.%s", caption.ID, contract.Name, field.Name)
		}
	}
	return nil
}

// Select only compiler-accepted, source-current evidence. An exported shape is
// descriptive, not a proof that a Rust implementation meets its Host premises.
func currentLeanEnvironment(root string, results []Result) (map[string]LeanContract, error) {
	contracts := map[string]LeanContract{}
	for _, result := range results {
		if result.Status != "PASS" || result.Lean == nil || result.Lean.Environment == nil {
			continue
		}
		if err := validateLeanEnvironment(result.Lean.Environment); err != nil {
			return nil, err
		}
		if !filepath.IsLocal(result.Lean.Source) || !strings.HasPrefix(result.Lean.Source, "dev/proofs/") {
			return nil, fmt.Errorf("nonlocal Lean environment source: %s", result.Lean.Source)
		}
		hash, err := fileSHA256(filepath.Join(root, result.Lean.Source))
		if err != nil {
			return nil, err
		}
		if hash != result.Lean.SourceSHA256 {
			return nil, fmt.Errorf("Lean environment source changed: %s", result.Lean.Source)
		}
		for _, contract := range result.Lean.Environment.Declarations {
			if _, duplicate := contracts[contract.Name]; duplicate {
				return nil, fmt.Errorf("ambiguous Lean environment declaration: %s", contract.Name)
			}
			contracts[contract.Name] = contract
		}
	}
	return contracts, nil
}
