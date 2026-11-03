// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSchemePreparationFailureKeepsOriginalCutWithoutAmbientReceipt(t *testing.T) {
	root, directory := t.TempDir(), t.TempDir()
	t.Setenv("WEAVER_SCHEME_LINK_RECEIPT", filepath.Join(root, "stale-global-receipt"))
	output := "... build github.com/tao3k/gerbil-ascent\n*** ERROR IN std/misc/process#run-process -- exit status 124\n"
	if err := os.WriteFile(filepath.Join(directory, "preparation.log"), []byte(output), 0600); err != nil {
		t.Fatal(err)
	}
	code := 70 // Gerbil dependency-manager status, not the nested build's 124.
	receipt := Receipt{Mode: "check-scheme", Status: "RUNNING", LinkedSourceHeads: map[string]string{"agentic-ai-lab": "original-source"},
		LinkedSourceSHA256: "original-cut", Stages: []Result{{Name: "scheme-preparation", Status: "FAIL", Log: "preparation.log", ExitCode: &code}}}
	if err := writeReceipt(directory, receipt); err != nil {
		t.Fatal(err)
	}
	path, err := publishLatestResult(root, directory, "check-scheme", errors.New("dependency preparation failed"))
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var retained Receipt
	if err := json.Unmarshal(data, &retained); err != nil {
		t.Fatal(err)
	}
	if retained.Status != "FAIL" || retained.LinkedSourceHeads["agentic-ai-lab"] != "original-source" ||
		retained.LinkedSourceSHA256 != "original-cut" || len(retained.Stages) != 1 ||
		!strings.Contains(retained.Stages[0].FailureTail, "exit status 124") || *retained.Stages[0].ExitCode != 70 {
		t.Fatalf("original cut, nested failure or parent exit lost: %+v", retained)
	}
}

func TestLateCleanupFailureCannotRetainPassingReceipt(t *testing.T) {
	root, directory := t.TempDir(), t.TempDir()
	if err := writeReceipt(directory, Receipt{Mode: "check", Status: "PASS"}); err != nil {
		t.Fatal(err)
	}
	path, err := publishLatestResult(root, directory, "check", errors.New("actual prefix cleanup failed"))
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var receipt Receipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Status != "FAIL" || len(receipt.Stages) != 1 || receipt.Stages[0].Name != "run-finalization" ||
		!strings.Contains(receipt.Stages[0].Error, "prefix cleanup") {
		t.Fatal("cleanup error retained a passing result")
	}
}

func TestLatestResultKeepsFailureMeaningAndCleansTemporaryLogs(t *testing.T) {
	root := t.TempDir()
	for _, status := range []string{"FAIL", "PASS"} {
		directory, err := os.MkdirTemp("", "weaver-retention-test-")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.RemoveAll(directory) })
		output := strings.Repeat("prefix\n", 2000) + "original property counterexample\n"
		if err := os.WriteFile(filepath.Join(directory, "check.log"), []byte(output), 0600); err != nil {
			t.Fatal(err)
		}
		code := 0
		var failed error
		if status == "FAIL" {
			code = 7
			failed = errors.New("actual property failure")
		}
		receipt := Receipt{Mode: "check", Status: status, Revision: "exact-source", Inputs: map[string]string{"source": "digest"}, Stages: []Result{{Name: "property", Status: status, Log: "check.log", ExitCode: &code}}}
		if err := writeReceipt(directory, receipt); err != nil {
			t.Fatal(err)
		}
		path, err := publishLatestResult(root, directory, "check", failed)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(directory); !os.IsNotExist(err) {
			t.Fatal("per-run logs survived publication")
		}
		bytes, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var result Receipt
		if err := json.Unmarshal(bytes, &result); err != nil {
			t.Fatal(err)
		}
		stage := result.Stages[0]
		digest := sha256.Sum256([]byte(output))
		if result.Status != status || result.Revision != "exact-source" || stage.ExitCode == nil || *stage.ExitCode != code || stage.OutputSHA256 != hex.EncodeToString(digest[:]) || stage.Log != "" {
			t.Fatal("source, exit or output identity lost")
		}
		if status == "FAIL" && (!strings.Contains(stage.FailureTail, "original property counterexample") || len(stage.FailureTail) > int(failureTailBytes)) {
			t.Fatal("failure was hidden or output retention is unbounded")
		}
		if status == "PASS" && stage.FailureTail != "" {
			t.Fatal("successful output was retained as an error log")
		}
	}
	files, err := os.ReadDir(filepath.Join(root, ".cache/verification"))
	if err != nil || len(files) != 1 || files[0].Name() != "latest-check.json" {
		t.Fatal("old per-run artifacts accumulated")
	}
}

func TestFailureSummaryRetainsFirstCauseBeforePassingSuffix(t *testing.T) {
	directory := t.TempDir()
	output := strings.Repeat("compile progress\n", 1000) + "control readiness: original source deadline exceeded\n" + strings.Repeat("unrelated passing case\n", 3000) + "FAIL original exit\n"
	if err := os.WriteFile(filepath.Join(directory, "suite.log"), []byte(output), 0600); err != nil {
		t.Fatal(err)
	}
	result := Result{Status: "FAIL", Log: "suite.log"}
	if err := summarizeOutput(directory, &result); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(result.FailureTail, "original source deadline exceeded") || !strings.Contains(result.FailureTail, "FAIL original exit") || len(result.FailureTail) > int(failureTailBytes) {
		t.Fatal("first failure was lost or diagnostic storage grew")
	}
}

func FuzzFailureExcerptRetainsPrecedingDiagnostic(f *testing.F) {
	f.Add(uint16(0), uint16(0))
	f.Add(uint16(8191), uint16(8191))
	f.Fuzz(func(t *testing.T, prefix, suffix uint16) {
		const cause = "    gateway_test.go:42: original capacity deadline exceeded\n"
		const marker = "--- FAIL: TestGateway/PROTOBUF\n"
		output := strings.Repeat("passing progress\n", int(prefix%8192)) + cause + marker + strings.Repeat("later passing case\n", int(suffix%8192))
		excerpt, err := firstFailureExcerpt(strings.NewReader(output))
		if err != nil || len(excerpt) > 2048 || !strings.Contains(string(excerpt), cause) || !strings.Contains(string(excerpt), marker) {
			t.Fatalf("preceding diagnostic lost or retention unbounded: %q %v", excerpt, err)
		}
	})
}
