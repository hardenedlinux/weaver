//go:build schemeintegration && darwin

package devrunner

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// This is an explicitly instrumented SDK, never a substitute for acceptance of
// the original SDK. Only gerbil build/test launch Scheme; no auxiliary main,
// executable target or alternate test driver is introduced.
func TestGerbilSDKPhaseProbe(t *testing.T) {
	seed, sdk := os.Getenv("WEAVER_SCHEME_TEST_PREFIX"), os.Getenv("WEAVER_GERBIL_SOURCE")
	if seed == "" || sdk == "" {
		t.Skip("explicit package prefix and SDK source required")
	}
	mode := os.Getenv("WEAVER_SCHEME_PHASE_IMAGES")
	if mode != "existing" && mode != "cloned" && mode != "hardlinked" {
		t.Fatal("explicit existing/cloned/hardlinked image mode required")
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
	directory := t.TempDir()
	overlay := filepath.Join(directory, "sdk")
	if err := os.MkdirAll(filepath.Join(overlay, "tools"), 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(sdk, "tools/gxtest.ss")
	sourceHash, err := fileSHA256(path)
	if err != nil {
		t.Fatal(err)
	}
	source, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	replace := func(old, next string) {
		t.Helper()
		if strings.Count(text, old) != 1 {
			t.Fatal("SDK trace boundary changed", old)
		}
		text = strings.Replace(text, old, next, 1)
	}
	replace("./env)", ":gerbil/tools/env)")
	replace("(def (run-tests args filter features verbosity)", `(def (weaver-phase label)
  (when (getenv "WEAVER_SCHEME_PHASE_TRACE" #f)
    (call-with-output-file (list path: (getenv "WEAVER_SCHEME_PHASE_TRACE") append: #t)
      (lambda (p)
        (display (time->seconds (current-time)) p) (display "\t" p)
        (display label p) (display "\t" p) (display (cpu-time) p)
        (display "\t" p) (display (real-time) p) (newline p) (force-output p)))))

(def (run-tests args filter features verbosity)`)
	replace("(collect-files args))", "(begin (weaver-phase \"discovery-begin\") (let (r (collect-files args)) (weaver-phase \"discovery-end\") r)))")
	replace("(harness (prepare-harness files allow verbosity))", "(harness (begin (weaver-phase \"imports-begin\") (let (r (prepare-harness files allow verbosity)) (weaver-phase \"imports-end\") r)))")
	replace("(result  (test-run! harness))", "(result (begin (weaver-phase \"execution-begin\") (let (r (test-run! harness)) (weaver-phase \"execution-end\") r)))")
	replace("    (display-test-result result)", "    (display-test-result result)\n    (weaver-phase \"sdk-return\")")
	replace("(import-module file #f #t))", "(begin (weaver-phase (string-append \"module-begin:\" file)) (let (r (import-module file #f #t)) (weaver-phase (string-append \"module-end:\" file)) r)))")
	for name, body := range map[string]string{"tools/gxtest.ss": text, "gerbil.pkg": "(package: gerbil)\n", "build.ss": "#!/usr/bin/env gxi\n(import :std/build-script)\n(defbuild-script '(\"tools/gxtest\"))\n"} {
		if err := os.WriteFile(filepath.Join(overlay, name), []byte(body), 0755); err != nil {
			t.Fatal(err)
		}
	}
	modifiedHash, err := fileSHA256(filepath.Join(overlay, "tools/gxtest.ss"))
	if err != nil {
		t.Fatal(err)
	}
	settings := map[string]string{"GERBIL_PATH": overlay, "GERBIL_LOADPATH": filepath.Join(seed, "lib"), "GERBIL_BUILD_CORES": fmt.Sprint(runtime.NumCPU())}
	sdkBuild := runStage(context.Background(), overlay, directory, Environment(settings), Stage{Name: "sdk-phase-build", Binary: tool, Args: []string{"build", "-g"}})
	retainPairOutput(t, directory, &sdkBuild)
	if sdkBuild.Status != "PASS" {
		t.Fatalf("SDK probe compilation: %s %s", sdkBuild.Error, sdkBuild.FailureTail)
	}
	productBuild := Result{Status: "NOT_RUN"}
	if mode != "existing" {
		prefix := filepath.Join(directory, "prefix")
		if err := cloneSchemePrefix(seed, prefix, mode == "hardlinked"); err != nil {
			t.Fatal(err)
		}
		seed = prefix
		if err := os.RemoveAll(filepath.Join(prefix, "lib/hardenedlinux/weaver")); err != nil {
			t.Fatal(err)
		}
		settings["GERBIL_PATH"] = prefix
		settings["GERBIL_LOADPATH"] = filepath.Join(prefix, "lib")
		settings["PKG_CONFIG_PATH"] = filepath.Join(prefix, "lib/pkgconfig")
		settings["WEAVER_POLICY_PKG_CONFIG_PACKAGE"] = "weaver-policy-ffi"
		productBuild = runStage(context.Background(), root, directory, Environment(settings), Stage{Name: "phase-product-build", Binary: tool, Args: []string{"build", "-g"}})
		retainPairOutput(t, directory, &productBuild)
		if productBuild.Status != "PASS" {
			t.Fatal(productBuild.FailureTail)
		}
	}
	trace := filepath.Join(directory, "phases.tsv")
	settings["GERBIL_PATH"] = seed
	settings["GERBIL_LOADPATH"] = filepath.Join(overlay, "lib") + string(os.PathListSeparator) + filepath.Join(seed, "lib")
	settings["WEAVER_SCHEME_PHASE_TRACE"] = trace
	var samples []schemeNativeSample
	var join func()
	onStart := func(pid int) { join = sampleSchemePhases(t, pid, trace, directory, &samples) }
	started := time.Now()
	result := runStageObserved(context.Background(), root, directory, Environment(settings), Stage{Name: "scheme-unit-tests", Binary: tool, Args: []string{"test", "-g", "-v", "5", "t"}}, true, onStart)
	finished := time.Now()
	if join != nil {
		join()
	}
	retainPairOutput(t, directory, &result)
	traceData, err := os.ReadFile(trace)
	if err != nil {
		t.Fatal("trace missing; SDK overlay was not proven active", err, result.FailureTail)
	}
	after, err := SourceInputs(root)
	stable := err == nil && maps.Equal(before, after)
	report := struct {
		DiagnosticOnly bool                 `json:"diagnosticOnly"`
		Images         string               `json:"images"`
		CPUs           int                  `json:"cpus"`
		OriginalSDK    string               `json:"originalSdkSha256"`
		ModifiedSDK    string               `json:"modifiedSdkSha256"`
		Start          string               `json:"start"`
		Finish         string               `json:"finish"`
		Stable         bool                 `json:"stable"`
		SDKBuild       Result               `json:"sdkBuild"`
		ProductBuild   Result               `json:"productBuild"`
		Test           Result               `json:"test"`
		Trace          string               `json:"trace"`
		Samples        []schemeNativeSample `json:"samples"`
		Inputs         map[string]string    `json:"inputs"`
	}{true, mode, runtime.NumCPU(), sourceHash, modifiedHash, started.Format(time.RFC3339Nano), finished.Format(time.RFC3339Nano), stable, sdkBuild, productBuild, result, string(traceData), samples, before}
	data, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".cache/verification/latest-scheme-phase-"+mode+".json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	t.Logf("diagnostic only %s: %s %s; trace %s", mode, result.Status, result.Duration, traceData)
	if !stable {
		t.Error("source changed")
	}
	if result.Status != "PASS" {
		t.Error("SDK diagnostic did not complete; failed trace retained")
	}
}

type schemeNativeSample struct {
	Phase              string `json:"phase"`
	Error              string `json:"error,omitempty"`
	SHA256             string `json:"sha256,omitempty"`
	MainSamples        string `json:"mainSamples,omitempty"`
	Validation         string `json:"validation,omitempty"`
	LoadNotification   string `json:"loadNotification,omitempty"`
	UnloadNotification string `json:"unloadNotification,omitempty"`
}

// Sampling is optional, explicit, bounded and diagnostic. It never participates
// in a timing acceptance arm or changes the target's exit/cleanup behavior.
func sampleSchemePhases(t *testing.T, pid int, trace, directory string, results *[]schemeNativeSample) func() {
	selected := os.Getenv("WEAVER_SCHEME_SAMPLE_TOOL")
	if selected == "" {
		return func() {}
	}
	tool, err := exec.LookPath(selected)
	if err != nil {
		*results = append(*results, schemeNativeSample{Phase: "sampler-setup", Error: err.Error()})
		return func() {}
	}
	stop, done := make(chan struct{}), make(chan struct{})
	var workers sync.WaitGroup
	var mu sync.Mutex
	go func() {
		defer close(done)
		ticker := time.NewTicker(5 * time.Millisecond)
		defer ticker.Stop()
		seen := map[string]bool{}
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				data, err := os.ReadFile(trace)
				if err != nil {
					continue
				}
				for _, phase := range []string{"imports-begin", "sdk-return"} {
					if seen[phase] || !strings.Contains(string(data), "\t"+phase+"\t") {
						continue
					}
					seen[phase] = true
					workers.Add(1)
					go func(phase string) {
						defer workers.Done()
						path := filepath.Join(directory, phase+".sample")
						cmd := exec.Command(tool, fmt.Sprint(pid), "1", "10", "-file", path)
						output, err := cmd.CombinedOutput()
						row := schemeNativeSample{Phase: phase}
						if err != nil {
							row.Error = fmt.Sprintf("%v %s", err, output)
						}
						if body, readErr := os.ReadFile(path); readErr == nil {
							row.SHA256, _ = fileSHA256(path)
							for _, line := range strings.Split(string(body), "\n") {
								switch {
								case strings.Contains(line, "com.apple.main-thread"):
									row.MainSamples = strings.TrimSpace(line)
								case strings.Contains(line, "SyscallDelegate::fcntl"):
									row.Validation = strings.TrimSpace(line)
								case strings.Contains(line, "notifyDebuggerLoad"):
									row.LoadNotification = strings.TrimSpace(line)
								case strings.Contains(line, "notifyDebuggerUnload"):
									row.UnloadNotification = strings.TrimSpace(line)
								}
							}
						}
						mu.Lock()
						*results = append(*results, row)
						mu.Unlock()
					}(phase)
				}
			}
		}
	}()
	return func() { close(stop); <-done; workers.Wait() }
}
