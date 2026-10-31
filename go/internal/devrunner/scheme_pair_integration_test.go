//go:build schemeintegration && darwin

package devrunner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
)

type schemePairTrial struct {
	Index   int    `json:"index"`
	Capture string `json:"capture"`
	Images  string `json:"images"`
	Build   Result `json:"build"`
	Test    Result `json:"test"`
}

type schemePairStudy struct {
	Kind       string            `json:"kind"`
	Revision   string            `json:"revision"`
	CPUs       int               `json:"cpus"`
	Stable     bool              `json:"stable"`
	ColdScope  string            `json:"coldScope"`
	Inputs     map[string]string `json:"inputs"`
	SeedSHA256 string            `json:"seedSha256"`
	SDK        string            `json:"sdk"`
	SDKSHA256  string            `json:"sdkSha256"`
	Trials     []schemePairTrial `json:"trials"`
}

// Each invocation owns one fixed matrix slot. The Go test watchdog remains at
// its default; compiler time cannot consume a batch's entire ten-minute budget.
func TestGerbilColdOutputPairs(t *testing.T) {
	seed := os.Getenv("WEAVER_SCHEME_TEST_PREFIX")
	if seed == "" {
		t.Skip("explicit prepared dependency prefix required")
	}
	index, err := strconv.Atoi(os.Getenv("WEAVER_SCHEME_PAIR_INDEX"))
	if err != nil {
		t.Fatal("explicit fixed matrix index required")
	}
	kind := os.Getenv("WEAVER_SCHEME_PAIR_KIND")
	var streamed, shared bool
	switch kind {
	case "output":
		order := []bool{false, true, true, false, true, false, false, true}
		if index < 0 || index >= len(order) {
			t.Fatal("invalid output matrix index")
		}
		streamed = order[index]
	case "images":
		order := []bool{false, true, true, false}
		if index < 0 || index >= len(order) {
			t.Fatal("invalid image matrix index")
		}
		streamed = true
		shared = order[index]
	default:
		t.Fatal("explicit output or images study required")
	}
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	before, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	tool, err := resolveBuildTool(root, schemeTool(), Environment(nil))
	if err != nil {
		t.Fatal(err)
	}
	sdkHash, err := fileSHA256(tool)
	if err != nil {
		t.Fatal(err)
	}
	seedHash, err := schemeSeedHash(seed)
	if err != nil {
		t.Fatal(err)
	}
	commit := exec.Command("git", "-C", root, "rev-parse", "HEAD")
	revision, err := commit.Output()
	if err != nil {
		t.Fatal(err)
	}
	report := schemePairStudy{Kind: kind, Revision: strings.TrimSpace(string(revision)), CPUs: runtime.NumCPU(), Stable: true,
		ColdScope: "fresh prefix paths; all product libraries removed/rebuilt by gerbil build; dependency image inode identity is the image-study intervention; OS caches uncontrolled",
		Inputs:    before, SeedSHA256: seedHash, SDK: tool, SDKSHA256: sdkHash}
	path := filepath.Join(root, ".cache/verification/latest-scheme-"+kind+"-pairs.json")
	if data, err := os.ReadFile(path); err == nil {
		var previous schemePairStudy
		if err := json.Unmarshal(data, &previous); err != nil {
			t.Fatal(err)
		}
		if previous.Kind != kind || previous.Revision != report.Revision || previous.CPUs != report.CPUs || previous.SeedSHA256 != seedHash || previous.SDKSHA256 != sdkHash || !maps.Equal(previous.Inputs, before) || !previous.Stable {
			t.Fatal("study inputs changed; retain and curate the previous cohort before starting another")
		}
		report.Trials = previous.Trials
	} else if !os.IsNotExist(err) {
		t.Fatal(err)
	}
	for _, old := range report.Trials {
		if old.Index == index {
			t.Fatal("a completed slot is immutable; do not overwrite a failed trial with a replay")
		}
	}
	directory := t.TempDir()
	prefix := filepath.Join(directory, "prefix")
	if err := cloneSchemePrefix(seed, prefix, shared); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(prefix, "lib/hardenedlinux/weaver")); err != nil {
		t.Fatal(err)
	}
	static, err := filepath.Glob(filepath.Join(prefix, "lib/static/hardenedlinux__weaver*"))
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range static {
		if err := os.RemoveAll(path); err != nil {
			t.Fatal(err)
		}
	}
	environment := Environment(map[string]string{"GERBIL_PATH": prefix, "GERBIL_LOADPATH": filepath.Join(prefix, "lib"), "GERBIL_BUILD_CORES": fmt.Sprint(runtime.NumCPU()), "PKG_CONFIG_PATH": filepath.Join(prefix, "lib/pkgconfig"), "WEAVER_POLICY_PKG_CONFIG_PACKAGE": "weaver-policy-ffi"})
	row := schemePairTrial{Index: index, Capture: "file", Images: "cloned", Test: Result{Status: "NOT_RUN"}}
	if streamed {
		row.Capture = "pipe"
	}
	if shared {
		row.Images = "hardlinked"
	}
	row.Build = runStage(context.Background(), root, directory, environment, Stage{Name: "scheme-build", Binary: tool, Args: []string{"build", "-g"}})
	retainPairOutput(t, directory, &row.Build)
	if row.Build.Status == "PASS" {
		row.Test = runStageCapture(context.Background(), root, directory, environment, Stage{Name: "scheme-unit-tests", Binary: tool, Args: []string{"test", "-g", "-v", "5", "t"}}, streamed)
		retainPairOutput(t, directory, &row.Test)
	}
	report.Trials = append(report.Trials, row)
	after, err := SourceInputs(root)
	report.Stable = err == nil && maps.Equal(before, after)
	afterSeed, err := schemeSeedHash(seed)
	report.Stable = report.Stable && err == nil && afterSeed == seedHash
	data, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".pending", data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path+".pending", path); err != nil {
		t.Fatal(err)
	}
	t.Logf("slot %d %s/%s: build %s %s; test %s %s; phases %+v", index, row.Capture, row.Images, row.Build.Status, row.Build.Duration, row.Test.Status, row.Test.Duration, row.Test.SchemeTiming)
	if !report.Stable {
		t.Error("source or shared seed changed")
	}
	if row.Build.Status != "PASS" || row.Test.Status != "PASS" {
		t.Error("fixed trial did not qualify; failure retained in the study receipt")
	}
}

func retainPairOutput(t *testing.T, directory string, result *Result) {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(directory, result.Log))
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(body)
	result.OutputSHA256 = hex.EncodeToString(digest[:])
	result.Log = ""
	if result.Status != "PASS" {
		if len(body) > 8192 {
			body = body[len(body)-8192:]
		}
		result.FailureTail = string(body)
	}
}

func schemeSeedHash(source string) (string, error) {
	h := sha256.New()
	err := filepath.WalkDir(filepath.Join(source, "lib"), func(path string, entry fs.DirEntry, visitErr error) error {
		if visitErr != nil {
			return visitErr
		}
		if entry.IsDir() || filepath.Ext(path) != ".o1" {
			return nil
		}
		digest, err := fileSHA256(path)
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(h, "%s\t%s\n", relative, digest)
		return err
	})
	return hex.EncodeToString(h.Sum(nil)), err
}

func cloneSchemePrefix(source, target string, shared bool) error {
	return filepath.WalkDir(source, func(path string, entry fs.DirEntry, visitErr error) error {
		if visitErr != nil {
			return visitErr
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		out := filepath.Join(target, relative)
		switch {
		case entry.IsDir():
			return os.Mkdir(out, 0700)
		case entry.Type()&os.ModeSymlink != 0:
			link, err := os.Readlink(path)
			if err != nil {
				return err
			}
			return os.Symlink(link, out)
		case entry.Type().IsRegular():
			if shared && filepath.Ext(path) == ".o1" {
				return os.Link(path, out)
			}
			return unix.Clonefile(path, out, unix.CLONE_NOFOLLOW)
		default:
			return fmt.Errorf("unexpected prefix artifact type: %s", path)
		}
	})
}
