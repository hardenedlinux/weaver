//go:build schemeintegration

package devrunner

import (
	"context"
	"encoding/json"
	"maps"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// Reuse an explicitly prepared standard package environment. This test owns
// neither dependency installation nor an alternate Scheme test driver.
func TestGerbilPackageEntryNaturalExit(t *testing.T) {
	prefix := os.Getenv("WEAVER_SCHEME_TEST_PREFIX")
	if prefix == "" {
		t.Skip("explicit standard package prefix required")
	}
	if !filepath.IsAbs(prefix) {
		t.Fatal("package prefix must be absolute")
	}
	working, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(working)
	if err != nil {
		t.Fatal(err)
	}
	before, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	report := struct {
		Entry           string            `json:"entry"`
		CPUs            int               `json:"cpus"`
		DeadlineSeconds int               `json:"deadlineSeconds"`
		Stable          bool              `json:"stable"`
		Trials          []Result          `json:"trials"`
		Inputs          map[string]string `json:"inputs"`
	}{Entry: "gerbil test -g -v 5 t", CPUs: runtime.NumCPU(), DeadlineSeconds: int(schemePackageTestTimeout / time.Second), Inputs: before}
	defer func() {
		after, err := SourceInputs(root)
		report.Stable = err == nil && maps.Equal(before, after)
		if !report.Stable {
			t.Error("source changed during package qualification", err)
		}
		data, err := json.MarshalIndent(report, "", "  ")
		if err != nil {
			t.Error(err)
			return
		}
		path := filepath.Join(root, ".cache/verification/latest-scheme-package.json")
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Error(err)
			return
		}
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Error(err)
		}
	}()
	for i := 0; i < 4; i++ {
		directory := t.TempDir()
		result := runStage(context.Background(), root, directory,
			Environment(map[string]string{"GERBIL_PATH": prefix}),
			Stage{Name: "scheme-unit-tests", Binary: schemeTool(), Args: []string{"test", "-g", "-v", "5", "t"}})
		body, err := os.ReadFile(filepath.Join(directory, result.Log))
		if err != nil {
			t.Fatal(err)
		}
		if err := summarizeOutput(directory, &result); err != nil {
			t.Fatal(err)
		}
		report.Trials = append(report.Trials, result)
		t.Logf("package trial %d: %s %s", i, result.Status, result.Duration)
		if result.Status != "PASS" {
			t.Errorf("standard package test failed: %s\n%s", result.Error, body)
		}
	}
}
