package devrunner

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type leanTrace struct {
	ID        string                               `json:"id"`
	Witnesses []struct{ File, Declaration string } `json:"witnesses"`
}

func readLeanTraces(root string) ([]leanTrace, error) {
	data, err := os.ReadFile(filepath.Join(root, "dev/sysml/runtime-trace.json"))
	if err != nil {
		return nil, err
	}
	var traces []leanTrace
	err = json.Unmarshal(data, &traces)
	return traces, err
}

type ProofReference struct {
	Requirement string `json:"requirement"`
	Source      string `json:"source"`
	Declaration string `json:"declaration"`
	Status      string `json:"status"`
}

// Coverage never upgrades a named candidate to checked evidence. A CHECKED
// reference still says nothing about materializing the theorem's Host premises.
func proofReferences(root string, results []Result) ([]ProofReference, error) {
	traces, err := readLeanTraces(root)
	if err != nil {
		return nil, err
	}
	var refs []ProofReference
	for _, trace := range traces {
		for _, witness := range trace.Witnesses {
			if witness.Declaration == "" {
				continue
			}
			ref := ProofReference{Requirement: trace.ID, Source: witness.File, Declaration: witness.Declaration, Status: "NOT_EXECUTED"}
			for _, result := range results {
				if result.Lean == nil || result.Lean.Source != witness.File {
					continue
				}
				ref.Status = "FAILED"
				if result.Status != "PASS" {
					continue
				}
				hash, err := fileSHA256(filepath.Join(root, witness.File))
				if err != nil {
					return nil, err
				}
				if hash != result.Lean.SourceSHA256 {
					ref.Status = "STALE_SOURCE"
					continue
				}
				for _, declaration := range result.Lean.Declarations {
					if declaration.Name == witness.Declaration {
						ref.Status = "CHECKED"
					}
				}
			}
			refs = append(refs, ref)
		}
	}
	return refs, nil
}
