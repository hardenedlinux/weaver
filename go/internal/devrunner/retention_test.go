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
