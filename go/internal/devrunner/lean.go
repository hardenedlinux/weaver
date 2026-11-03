// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// LeanEvidence records compiler messages, not a proof of the Rust implementation.
// Source-currentness and the process result remain independent acceptance checks.
type LeanEvidence struct {
	Source       string            `json:"source"`
	SourceSHA256 string            `json:"sourceSha256"`
	Diagnostics  []LeanDiagnostic  `json:"diagnostics"`
	Declarations []LeanDeclaration `json:"declarations"`
	Environment  *LeanEnvironment  `json:"environment,omitempty"`
}

// LeanEnvironment is reflected by Lean from its imported environment. Go must
// not reconstruct these declarations from source text or SysML prose.
type LeanEnvironment struct {
	Schema       string         `json:"schema"`
	Declarations []LeanContract `json:"declarations"`
}
type LeanContract struct {
	Name   string      `json:"name"`
	Type   string      `json:"type"`
	Fields []LeanField `json:"fields"`
	Value  string      `json:"value,omitempty"`
}
type LeanField struct {
	Name      string `json:"name"`
	Type      string `json:"type"`
	Condition bool   `json:"condition"`
}
type LeanDiagnostic struct {
	FileName string `json:"fileName"`
	Severity string `json:"severity"`
	Data     string `json:"data"`
	Pos      struct {
		Line   int `json:"line"`
		Column int `json:"column"`
	} `json:"pos"`
}
type LeanDeclaration struct {
	Name         string   `json:"name"`
	Axioms       []string `json:"axioms"`
	Requirements []string `json:"requirements,omitempty"`
}

func leanSource(stage Stage) string {
	if stage.Binary == "elan" && len(stage.Args) == 5 && stage.Args[0] == "run" &&
		stage.Args[1] == proofToolchain && stage.Args[2] == "lean" && stage.Args[3] == "--json" &&
		filepath.IsLocal(stage.Args[4]) && strings.HasSuffix(stage.Args[4], ".lean") {
		return stage.Args[4]
	}
	if stage.Binary == "elan" && len(stage.Args) == 9 && stage.Args[0] == "run" &&
		stage.Args[1] == proofToolchain && stage.Args[2] == "lake" && stage.Args[3] == "-d" &&
		stage.Args[4] == "dev/proofs/cedar" && stage.Args[5] == "env" && stage.Args[6] == "lean" &&
		stage.Args[7] == "--json" && stage.Args[8] == "dev/proofs/cedar/ZeroTrustArchitecture.lean" {
		return stage.Args[8]
	}
	return ""
}

var leanAxioms = regexp.MustCompile(`^'([^']+)' (?:does not depend on any axioms|depends on axioms: \[([^\]]*)\])$`)

func readLeanEvidence(root, source, logPath string) (*LeanEvidence, error) {
	hash, err := fileSHA256(filepath.Join(root, source))
	if err != nil {
		return nil, err
	}
	evidence := &LeanEvidence{Source: source, SourceSHA256: hash}
	file, err := os.Open(logPath)
	if err != nil {
		return evidence, err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 16<<20)
	seen := map[string]bool{}
	var failures []error
	for scanner.Scan() {
		var diagnostic LeanDiagnostic
		if err := json.Unmarshal(scanner.Bytes(), &diagnostic); err != nil {
			return evidence, fmt.Errorf("Lean JSON diagnostic: %w", err)
		}
		fileName := filepath.Clean(diagnostic.FileName)
		if filepath.IsAbs(fileName) {
			fileName, err = filepath.Rel(root, fileName)
		}
		if err != nil || fileName != filepath.Clean(source) || diagnostic.Data == "" || diagnostic.Pos.Line <= 0 {
			return evidence, errors.New("Lean diagnostic does not bind the selected source")
		}
		evidence.Diagnostics = append(evidence.Diagnostics, diagnostic)
		if strings.HasPrefix(diagnostic.Data, "{\"schema\":") || strings.HasPrefix(diagnostic.Data, "{\"declarations\":") {
			var environment LeanEnvironment
			if err := json.Unmarshal([]byte(diagnostic.Data), &environment); err != nil {
				return evidence, fmt.Errorf("Lean environment JSON: %w", err)
			}
			if evidence.Environment != nil || diagnostic.Severity != "information" {
				return evidence, errors.New("duplicate or non-information Lean environment")
			}
			if err := validateLeanEnvironment(&environment); err != nil {
				return evidence, err
			}
			evidence.Environment = &environment
		}
		switch diagnostic.Severity {
		case "information", "warning":
		case "error":
			failures = append(failures, errors.New(diagnostic.Data))
		default:
			return evidence, errors.New("unknown Lean diagnostic severity")
		}
		if strings.Contains(diagnostic.Data, "declaration uses 'sorry'") {
			failures = append(failures, errors.New("Lean reports an incomplete proof"))
		}
		match := leanAxioms.FindStringSubmatch(diagnostic.Data)
		if match == nil {
			continue
		}
		if seen[match[1]] {
			return evidence, errors.New("duplicate Lean declaration audit")
		}
		seen[match[1]] = true
		declaration := LeanDeclaration{Name: match[1], Axioms: []string{}}
		if match[2] != "" {
			for _, field := range strings.Split(match[2], ",") {
				axiom := strings.TrimSpace(field)
				declaration.Axioms = append(declaration.Axioms, axiom)
				if axiom != "propext" && axiom != "Quot.sound" && axiom != "Classical.choice" {
					failures = append(failures, fmt.Errorf("unapproved Lean axiom: %s", axiom))
				}
			}
		}
		evidence.Declarations = append(evidence.Declarations, declaration)
	}
	if scanner.Err() != nil {
		failures = append(failures, scanner.Err())
	}
	if len(evidence.Declarations) == 0 {
		failures = append(failures, errors.New("Lean declaration audit missing"))
	}
	if err := requireLeanTrace(root, evidence); err != nil {
		failures = append(failures, err)
	}
	return evidence, errors.Join(failures...)
}

func requireLeanTrace(root string, evidence *LeanEvidence) error {
	traces, err := readLeanTraces(root)
	if err != nil {
		return err
	}
	checked := map[string]int{}
	for index, declaration := range evidence.Declarations {
		checked[declaration.Name] = index
	}
	for _, trace := range traces {
		for _, witness := range trace.Witnesses {
			if witness.File == evidence.Source && witness.Declaration != "" {
				index, found := checked[witness.Declaration]
				if !found {
					return fmt.Errorf("requirement %s lacks checked Lean declaration %s", trace.ID, witness.Declaration)
				}
				evidence.Declarations[index].Requirements = append(evidence.Declarations[index].Requirements, trace.ID)
			}
		}
	}
	return nil
}
