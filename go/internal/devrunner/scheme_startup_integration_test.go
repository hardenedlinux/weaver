//go:build schemeintegration && !windows

package devrunner

import (
	"context"
	"crypto/sha256"
	"debug/macho"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"hash"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

var startupSource = flag.String("scheme-source", "", "Pinned Agentic AI Lab source")
var startupPoo = flag.String("scheme-poo", "", "Inherited pinned POO source")
var startupPrepared = flag.String("scheme-prepared-environment", "", "Explicit source-checked isolated preparation receipt; caller owns its cleanup")
var startupCommitted = flag.Bool("scheme-require-committed", false, "Require qualification inputs to match HEAD")
var startupProfile = flag.Bool("scheme-profile-phases", false, "Diagnostic owned-process sampling; never timing qualification")
var startupProfileDirectory string
var startupSampler string

func startupDigest(inputs map[string]string) string {
	keys := make([]string, 0, len(inputs))
	for key := range inputs {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	digest := sha256.New()
	for _, key := range keys {
		fmt.Fprintf(digest, "%s=%s\n", key, inputs[key])
	}
	return hex.EncodeToString(digest.Sum(nil))
}

type startupTrial struct {
	Profile      string                   `json:"profile"`
	Generation   int                      `json:"generation"`
	Elapsed      time.Duration            `json:"elapsedNs"`
	CPUUser      time.Duration            `json:"userCpuNs"`
	CPUSystem    time.Duration            `json:"systemCpuNs"`
	Phases       map[string]time.Duration `json:"phasesNs"`
	Cases        int                      `json:"cases"`
	ExitCode     int                      `json:"exitCode"`
	TimedOut     bool                     `json:"timedOut"`
	GroupClosed  bool                     `json:"groupClosed"`
	Diagnostics  bool                     `json:"diagnostics"`
	OutputSHA256 string                   `json:"outputSha256"`
	Failure      string                   `json:"failure,omitempty"`
}

type startupReport struct {
	Schema           string               `json:"schema"`
	Revision         string               `json:"revision"`
	Committed        bool                 `json:"committed"`
	Status           string               `json:"status"`
	Sampled          bool                 `json:"sampled"`
	DeadlineSeconds  int                  `json:"deadlineSeconds"`
	CPUs             int                  `json:"cpus"`
	SourceDigest     string               `json:"sourceDigest"`
	DependencyDigest string               `json:"dependencyDigest"`
	Stable           bool                 `json:"sourceStable"`
	ToolArtifacts    map[string]string    `json:"toolArtifacts"`
	ImageProfile     schemeImageProfile   `json:"imageProfile"`
	Controls         map[string]string    `json:"controls"`
	ControlUUIDs     map[string]string    `json:"controlUuids"`
	ControlInodes    map[string]uint64    `json:"controlInodes"`
	Preparation      []Result             `json:"preparation"`
	Trials           []startupTrial       `json:"trials"`
	Cleanup          []cleanupObservation `json:"cleanup"`
}

// Comparable shared stdout/stderr writer: os/exec serializes calls. All evidence
// is bounded; oversized lines cannot impersonate a phase or successful case.
type startupOutput struct {
	start         time.Time
	phases        map[string]time.Duration
	pending       []byte
	digest        hash.Hash
	tail          []byte
	dropLine      bool
	phaseObserved func(string)
	cases         int
	diagnostics   bool
}

func (o *startupOutput) Write(data []byte) (int, error) {
	if o.digest == nil {
		o.digest = sha256.New()
	}
	o.digest.Write(data)
	o.tail = append(o.tail, data...)
	if len(o.tail) > 2048 {
		o.tail = o.tail[len(o.tail)-2048:]
	}
	for _, character := range data {
		if character != '\n' {
			if len(o.pending) == 4096 {
				o.pending = o.pending[:0]
				o.dropLine = true
			}
			if !o.dropLine {
				o.pending = append(o.pending, character)
			}
			continue
		}
		if o.dropLine {
			o.dropLine = false
			continue
		}
		line := string(o.pending)
		o.pending = o.pending[:0]
		phase := ""
		switch {
		case line == "WEAVER-PHASE runtime":
			phase = "runtime"
		case line == "WEAVER-PHASE framework":
			phase = "framework"
		case line == "WEAVER-PHASE discover":
			phase = "discoveryStart"
		case strings.HasPrefix(line, "HARNESS ("):
			phase = "executionStart"
		case strings.HasPrefix(line, "HARNESS-OK ("):
			phase = "executionEnd"
		case line == "WEAVER-PHASE returned":
			phase = "cleanupStart"
		case strings.HasPrefix(line, "CASE-OK "):
			o.cases++
		case strings.Contains(line, "*** WARNING"), strings.Contains(line, "*** ERROR"), strings.HasPrefix(line, "CASE-FAIL"), strings.HasPrefix(line, "HARNESS-ERROR"):
			o.diagnostics = true
		}
		if phase != "" {
			if _, seen := o.phases[phase]; !seen {
				o.phases[phase] = time.Since(o.start)
				if o.phaseObserved != nil {
					o.phaseObserved(phase)
				}
			}
		}
	}
	return len(data), nil
}

func (trial startupTrial) qualified() bool {
	if trial.TimedOut || trial.ExitCode != 0 || !trial.GroupClosed || trial.Diagnostics || trial.Cases != 19 || trial.Elapsed > 15*time.Second {
		return false
	}
	previous := time.Duration(0)
	for _, phase := range []string{"runtime", "framework", "discoveryStart", "executionStart", "executionEnd", "cleanupStart"} {
		at, exists := trial.Phases[phase]
		if !exists || at < previous || at > trial.Elapsed {
			return false
		}
		previous = at
	}
	return true
}

func runStartupTrial(root, compiler, profile string, environment []string) startupTrial {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, compiler,
		"-e", `(displayln "WEAVER-PHASE runtime") (force-output) (dump-stack-trace? #f)`,
		"-e", `(import (prefix-in :gerbil/tools/gxtest tests.))`,
		"-e", `(displayln "WEAVER-PHASE framework") (force-output)`,
		"-e", `(displayln "WEAVER-PHASE discover") (force-output)`,
		"-e", `(unless (zero? (tests.main "-g" "-v" "5" "t")) (error "Scheme test suite failed"))`,
		"-e", `(displayln "WEAVER-PHASE returned") (force-output)`)
	cmd.Dir = root
	cmd.Env = environment
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	observed := &startupOutput{start: time.Now(), phases: map[string]time.Duration{}}
	var samplers sync.WaitGroup
	if *startupProfile && runtime.GOOS == "darwin" {
		observed.phaseObserved = func(phase string) {
			if phase != "discoveryStart" && phase != "cleanupStart" {
				return
			}
			samplers.Add(1)
			go func() {
				defer samplers.Done()
				path := filepath.Join(startupProfileDirectory, fmt.Sprintf("%s-%s-%d.sample", profile, phase, cmd.Process.Pid))
				exec.Command(startupSampler, fmt.Sprint(cmd.Process.Pid), "1", "1", "-mayDie", "-file", path).Run()
			}()
		}
	}
	cmd.Stdout = observed
	cmd.Stderr = observed
	err := cmd.Run()
	trial := startupTrial{Profile: profile, Elapsed: time.Since(observed.start), Phases: observed.phases, Cases: observed.cases, ExitCode: -1, TimedOut: ctx.Err() != nil, Diagnostics: observed.diagnostics}
	if observed.digest != nil {
		trial.OutputSHA256 = hex.EncodeToString(observed.digest.Sum(nil))
	}
	if cmd.ProcessState != nil {
		trial.ExitCode = cmd.ProcessState.ExitCode()
		trial.CPUUser = cmd.ProcessState.UserTime()
		trial.CPUSystem = cmd.ProcessState.SystemTime()
		trial.GroupClosed = syscall.Kill(-cmd.Process.Pid, 0) == syscall.ESRCH
		for !trial.GroupClosed && ctx.Err() == nil {
			time.Sleep(time.Millisecond)
			trial.GroupClosed = syscall.Kill(-cmd.Process.Pid, 0) == syscall.ESRCH
		}
		trial.Elapsed = time.Since(observed.start)
		trial.TimedOut = ctx.Err() != nil
		if !trial.GroupClosed {
			syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		} // Failed watchdog cleanup cannot qualify.
	}
	if err != nil {
		trial.Failure = err.Error() + "\n" + string(observed.tail)
	}
	samplers.Wait()
	return trial
}

func startupSettings(t *testing.T, root string, report *startupReport) map[string]string {
	t.Helper()
	if *startupPrepared != "" {
		var receipt struct {
			Environment  map[string]string `json:"environment"`
			SourceRoot   string            `json:"source_root"`
			PooSource    string            `json:"poo_source"`
			SourceHashes map[string]string `json:"source_hashes"`
		}
		data, err := os.ReadFile(*startupPrepared)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, &receipt); err != nil {
			t.Fatal(err)
		}
		current, err := schemeSourceHashes(receipt.SourceRoot, receipt.PooSource)
		if err != nil || !maps.Equal(current, receipt.SourceHashes) {
			t.Fatal("prepared sources no longer match receipt", err)
		}
		report.DependencyDigest = startupDigest(current)
		return receipt.Environment
	}
	if *startupSource == "" || *startupPoo == "" {
		t.Fatal("explicit pinned -scheme-source and -scheme-poo required")
	}
	settings, err := PrepareScheme(context.Background(), root, *startupSource, *startupPoo, "", os.Stdout)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(settings["GERBIL_PATH"]); err != nil {
			t.Error(err)
		}
	})
	current, err := schemeSourceHashes(*startupSource, *startupPoo)
	if err != nil {
		t.Fatal(err)
	}
	report.DependencyDigest = startupDigest(current)
	stages, err := Stages("check-scheme", filepath.Join(runtime.GOROOT(), "bin/go"))
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	for _, stage := range stages {
		if !strings.HasPrefix(stage.Name, "scheme-") || stage.Name == "scheme-unit-tests" || stage.Name == "scheme-grpc-stream-integration" || stage.Name == "scheme-dynamic-images" {
			continue
		}
		result := runStage(context.Background(), root, directory, Environment(settings), stage)
		if err := summarizeOutput(directory, &result); err != nil {
			t.Fatal(err)
		}
		report.Preparation = append(report.Preparation, result)
		t.Logf("prepare %s %s %s", stage.Name, result.Status, result.Duration)
		if result.Status != "PASS" {
			t.Fatalf("preparation failed: %s %s", result.Error, result.FailureTail)
		}
	}
	return settings
}

func startupBuild(t *testing.T, root string, environment []string, args ...string) {
	t.Helper()
	file, err := os.CreateTemp("", "weaver-image-command-*.log")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(file.Name()) })
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = root
	cmd.Env = environment
	cmd.Stdout = file
	cmd.Stderr = file
	err = cmd.Run()
	file.Close()
	if err != nil {
		body, _ := os.ReadFile(file.Name())
		if len(body) > 4096 {
			body = body[len(body)-4096:]
		}
		t.Fatalf("%v: %s", err, body)
	}
}

func controlOverlays(t *testing.T, root string, settings map[string]string, profile schemeImageProfile, generation string, report *startupReport) (string, string) {
	t.Helper()
	input := filepath.Dir(profile.Overlay)
	environment, err := imageCompilerEnvironment(Environment(settings))
	if err != nil {
		t.Fatal(err)
	}
	startupBuild(t, root, environment, "cargo", "run", "--locked", "--offline", "-p", "weaver-policy-ffi", "--example", "module_images", "--", "controls", input, generation)
	data, err := os.ReadFile(filepath.Join(generation, "controls.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	byPath := map[string]string{}
	for identity, path := range profile.Modules {
		byPath[path] = identity
	}
	separate := filepath.Join(generation, "separate-overlay")
	combined := filepath.Join(generation, "coalesced-overlay")
	seen := map[string]bool{}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) != 4 {
			t.Fatal("invalid same-object controls")
		}
		identity, known := byPath[fields[0]]
		if !known || seen[identity] {
			t.Fatal("ambiguous control identity")
		}
		seen[identity] = true
		for index, overlay := range []string{separate, combined} {
			alias := filepath.Join(overlay, identity+".o1")
			if err := os.MkdirAll(filepath.Dir(alias), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(fields[index+1], alias); err != nil {
				t.Fatal(err)
			}
			hash, err := imageFileHash(fields[index+1])
			if err != nil {
				t.Fatal(err)
			}
			report.Controls[fields[index+1]] = hash
			controlImageIdentity(t, fields[index+1], report)
		}
		hash, err := imageFileHash(fields[3])
		if err != nil {
			t.Fatal(err)
		}
		report.Controls[fields[3]] = hash
	}
	if len(seen) != len(profile.Bindings) {
		t.Fatal("controls lost a selected logical entry")
	}
	return separate, combined
}

func controlImageIdentity(t *testing.T, path string, report *startupReport) {
	t.Helper()
	if _, seen := report.ControlUUIDs[path]; seen {
		return
	}
	image, err := macho.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer image.Close()
	uuid := ""
	for _, load := range image.Loads {
		raw := load.Raw()
		if len(raw) == 24 && image.ByteOrder.Uint32(raw[:4]) == 0x1b {
			uuid = hex.EncodeToString(raw[8:24])
		}
	}
	if uuid == "" {
		t.Fatal("fresh control image has no UUID")
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("native inode absent")
	}
	for prior, id := range report.ControlUUIDs {
		if id == uuid {
			t.Fatalf("cold image UUID reused: %s %s", prior, path)
		}
	}
	for prior, inode := range report.ControlInodes {
		if inode == stat.Ino {
			t.Fatalf("cold image inode reused: %s %s", prior, path)
		}
	}
	report.ControlUUIDs[path] = uuid
	report.ControlInodes[path] = stat.Ino
}

type cleanupObservation struct {
	Profile      string `json:"profile"`
	ModuleOpens  int    `json:"moduleOpens"`
	ModuleCloses int    `json:"moduleCloses"`
	Outstanding  int    `json:"outstandingModuleRefs"`
	Errors       int    `json:"closeErrors"`
	Overflow     int    `json:"overflow"`
	PeakImages   int    `json:"peakDyldImages"`
	TraceSHA256  string `json:"traceSha256"`
	AliasedOpens int    `json:"aliasedOpens"`
}

func observeCleanup(t *testing.T, root, compiler string, profile schemeImageProfile, settings map[string]string, report *startupReport) {
	t.Helper()
	directory := t.TempDir()
	observer := filepath.Join(directory, "module-observer.dylib")
	startupBuild(t, root, Environment(settings), profile.Compiler, "-dynamiclib", "-o", observer, filepath.Join(root, "dev/scheme/module-observer.c"))
	probeCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	probe := exec.CommandContext(probeCtx, compiler, "-e", `(displayln (path-expand "bin/gxi" (gerbil-home)))`)
	probe.Env = Environment(settings)
	data, err := probe.Output()
	if err != nil {
		t.Fatal(err)
	}
	real := strings.TrimSpace(string(data))
	if !filepath.IsAbs(real) {
		t.Fatal("actual interpreter path absent")
	}
	hash, err := imageFileHash(real)
	if err != nil {
		t.Fatal(err)
	}
	report.ToolArtifacts[real] = hash
	header := filepath.Join(filepath.Dir(filepath.Dir(real)), "include/gambit.h")
	headerHash, err := imageFileHash(header)
	if err != nil {
		t.Fatal(err)
	}
	report.ToolArtifacts[header] = headerHash
	packageTool, err := resolveImageTool(root, "pkg-config", Environment(settings))
	if err != nil {
		t.Fatal(err)
	}
	packageQuery := exec.CommandContext(probeCtx, packageTool, "--variable=library", settings["WEAVER_POLICY_PKG_CONFIG_PACKAGE"])
	packageQuery.Env = Environment(settings)
	packageData, err := packageQuery.Output()
	if err != nil {
		t.Fatal(err)
	}
	ffi := strings.TrimSpace(string(packageData))
	if !filepath.IsAbs(ffi) {
		t.Fatal("pkg-config FFI artifact is not absolute")
	}
	ffiHash, err := imageFileHash(ffi)
	if err != nil {
		t.Fatal(err)
	}
	report.ToolArtifacts[ffi] = ffiHash
	for _, layout := range []string{"separate-diagnostic", "coalesced-diagnostic"} {
		current := maps.Clone(settings)
		current["GERBIL_HOME"] = filepath.Dir(filepath.Dir(real))
		home := current["GERBIL_HOME"]
		current["GERBIL_PREFIX"] = filepath.Dir(home)
		options := current["GAMBOPT"]
		if options != "" {
			options += ","
		}
		current["GAMBOPT"] = options + "~~=" + home + ",~~bin=" + home + "/bin,~~lib=" + home + "/lib"
		current["DYLD_INSERT_LIBRARIES"] = observer
		trace := filepath.Join(directory, layout+".json")
		timeline := filepath.Join(directory, layout+".tsv")
		current["WEAVER_MODULE_CLEANUP_TRACE"] = trace
		current["WEAVER_DYLD_TIMELINE"] = timeline
		if layout == "coalesced-diagnostic" {
			current["GERBIL_LOADPATH"] = profile.Overlay + ":" + current["GERBIL_LOADPATH"]
		}
		trial := runStartupTrial(root, real, layout, Environment(current))
		report.Trials = append(report.Trials, trial)
		if !trial.qualified() {
			t.Fatalf("instrumented diagnostic failed: %+v", trial)
		}
		data, err := os.ReadFile(trace)
		if err != nil {
			t.Fatal(err)
		}
		var observed cleanupObservation
		if err := json.Unmarshal(data, &observed); err != nil {
			t.Fatal(err)
		}
		observed.Profile = layout
		observed.TraceSHA256, err = imageFileHash(timeline)
		if err != nil {
			t.Fatal(err)
		}
		body, err := os.ReadFile(timeline)
		if err != nil || !strings.HasSuffix(string(body), "# eventOverflow=0\n") {
			t.Fatal("incomplete native trace", err)
		}
		for _, line := range strings.Split(string(body), "\n") {
			parts := strings.Split(line, "\t")
			if len(parts) == 5 && parts[0] == "L" && parts[1] == "1" && strings.HasPrefix(parts[4], profile.Overlay+"/") {
				observed.AliasedOpens++
			}
		}
		if layout == "coalesced-diagnostic" && observed.AliasedOpens != len(profile.Bindings) {
			t.Fatalf("selected logical entry coverage lost: %+v expected %d", observed, len(profile.Bindings))
		}
		if observed.ModuleOpens == 0 || observed.ModuleOpens != observed.ModuleCloses || observed.Outstanding != 0 || observed.Errors != 0 || observed.Overflow != 0 {
			t.Fatalf("incomplete natural dlclose: %+v", observed)
		}
		report.Cleanup = append(report.Cleanup, observed)
		t.Logf("cleanup %+v", observed)
	}
}

func TestDynamicSchemeColdStartPairs(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Darwin image-notification qualification")
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
	report := startupReport{Schema: "weaver.scheme-startup.v2", Status: "FAIL", Sampled: *startupProfile, CPUs: runtime.NumCPU(), DeadlineSeconds: 15, SourceDigest: startupDigest(before), ToolArtifacts: map[string]string{}, Controls: map[string]string{}, ControlUUIDs: map[string]string{}, ControlInodes: map[string]uint64{}}
	var settings map[string]string
	defer func() {
		after, err := SourceInputs(root)
		report.Stable = err == nil && maps.Equal(before, after)
		if !report.Stable {
			t.Error("project changed during qualification")
		}
		if settings != nil {
			current, err := schemeSourceHashes(settings["WEAVER_SCHEME_AGENTIC_SOURCE"], settings["WEAVER_SCHEME_POO_SOURCE"])
			if err != nil || startupDigest(current) != report.DependencyDigest {
				t.Error("dependency sources changed during qualification")
			}
		}
		if err := verifyImageFiles(report.ImageProfile.Inputs); err != nil {
			t.Error(err)
		}
		if err := verifyImageFiles(report.ImageProfile.Artifacts); err != nil {
			t.Error(err)
		}
		if err := verifyImageFiles(report.ImageProfile.Tools); err != nil {
			t.Error(err)
		}
		if err := verifyImageFiles(report.Controls); err != nil {
			t.Error(err)
		}
		if err := verifyImageFiles(report.ToolArtifacts); err != nil {
			t.Error(err)
		}
		if !t.Failed() {
			report.Status = "PASS"
			if *startupProfile {
				report.Status = "DIAGNOSTIC"
			}
		}
		data, err := json.MarshalIndent(report, "", "  ")
		if err != nil {
			t.Error(err)
			return
		}
		path := filepath.Join(root, ".cache/verification/latest-scheme-startup.json")
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Error(err)
			return
		}
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Error(err)
		}
	}()
	admission, revision := committedSource(context.Background(), root, t.TempDir(), "startup-source", "", before)
	report.Revision = revision
	report.Committed = admission.Status == "PASS"
	if *startupCommitted && !report.Committed {
		t.Fatal("qualification source is uncommitted", admission.Error)
	}
	settings = startupSettings(t, root, &report)
	if environmentMap(Environment(settings))["DYLD_INSERT_LIBRARIES"] != "" {
		t.Fatal("ordinary timing environment is instrumented")
	}
	startupProfileDirectory = filepath.Join(settings["GERBIL_PATH"], "profiles")
	if *startupProfile {
		if *startupCommitted {
			t.Fatal("sampled runs cannot qualify timing")
		}
		startupSampler, err = resolveImageTool(root, os.Getenv("WEAVER_SCHEME_SAMPLER"), Environment(settings))
		if err != nil {
			t.Fatal("explicit diagnostic sampler environment required", err)
		}
		if err := os.MkdirAll(startupProfileDirectory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	compiler := settings["WEAVER_CONTROL_SCHEME_COMPILER"]
	if hash, err := imageFileHash(compiler); err != nil {
		t.Fatal(err)
	} else {
		report.ToolArtifacts[compiler] = hash
	}
	baseline := runStartupTrial(root, compiler, "installed-layout", Environment(settings))
	report.Trials = append(report.Trials, baseline)
	t.Logf("original %+v", baseline)
	if baseline.Diagnostics || baseline.ExitCode > 0 {
		t.Fatal("baseline semantic failure cannot be a performance control")
	}
	file, err := os.CreateTemp("", "weaver-image-build-*.log")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(file.Name()) })
	_, profile, buildErr := prepareSchemeImages(context.Background(), root, Environment(settings), file)
	file.Close()
	report.ImageProfile = profile
	if buildErr != nil {
		body, _ := os.ReadFile(file.Name())
		if len(body) > 4096 {
			body = body[len(body)-4096:]
		}
		t.Fatalf("%v: %s", buildErr, body)
	}
	outputHash := ""
	if baseline.qualified() {
		outputHash = baseline.OutputSHA256
	}
	for generation := 0; generation < 4; generation++ {
		directory := t.TempDir()
		separate, combined := controlOverlays(t, root, settings, profile, directory, &report)
		order := []string{"separate", "coalesced", "coalesced", "separate"}
		if generation%2 == 1 {
			order = []string{"coalesced", "separate", "separate", "coalesced"}
		}
		for _, layout := range order {
			current := maps.Clone(settings)
			overlay := separate
			if layout == "coalesced" {
				overlay = combined
			}
			current["GERBIL_LOADPATH"] = overlay + ":" + current["GERBIL_LOADPATH"]
			trial := runStartupTrial(root, compiler, layout, Environment(current))
			trial.Generation = generation
			report.Trials = append(report.Trials, trial)
			t.Logf("cold %+v", trial)
			if trial.qualified() {
				if outputHash == "" {
					outputHash = trial.OutputSHA256
				}
				if trial.OutputSHA256 != outputHash {
					t.Error("same-object layout changed standard test output")
				}
			}
			if layout == "coalesced" && !trial.qualified() {
				t.Errorf("coalesced trial failed fixed gate: %+v", trial)
			}
			if layout == "separate" && (trial.Diagnostics || trial.ExitCode > 0) {
				t.Fatal("same-object baseline semantic failure")
			}
		}
	}
	observeCleanup(t, root, compiler, profile, settings, &report)
}

func TestStartupPhasesRequireNaturalCompletionAndAllCases(t *testing.T) {
	output := &startupOutput{start: time.Now(), phases: map[string]time.Duration{}}
	body := "WEAVER-PHASE runtime\nWEAVER-PHASE framework\nWEAVER-PHASE discover\nHARNESS (fixtures)\n" + strings.Repeat("CASE-OK assertion\n", 19) + "HARNESS-OK (fixtures)\nWEAVER-PHASE returned\n"
	for _, character := range []byte(body) {
		output.Write([]byte{character})
	}
	trial := startupTrial{Elapsed: time.Since(output.start), Phases: output.phases, Cases: output.cases, ExitCode: 0, GroupClosed: true}
	if !trial.qualified() {
		t.Fatal("split observations lost the completed suite")
	}
	for _, corrupt := range []func(*startupTrial){func(p *startupTrial) { p.TimedOut = true }, func(p *startupTrial) { p.ExitCode = 70 }, func(p *startupTrial) { p.GroupClosed = false }, func(p *startupTrial) { p.Cases-- }, func(p *startupTrial) { p.Elapsed = 15*time.Second + 1 }, func(p *startupTrial) { p.Diagnostics = true }} {
		changed := trial
		corrupt(&changed)
		if changed.qualified() {
			t.Fatal("incomplete, warned, or forced process accepted")
		}
	}
	delete(trial.Phases, "cleanupStart")
	if trial.qualified() {
		t.Fatal("harness success substituted for caller return")
	}
}

func TestStartupObserverBoundsFailureOutput(t *testing.T) {
	output := &startupOutput{start: time.Now(), phases: map[string]time.Duration{}}
	output.Write([]byte(strings.Repeat("x", 100000) + "HARNESS (forged)\n"))
	if len(output.tail) > 2048 || len(output.pending) > 4096 || len(output.phases) != 0 {
		t.Fatal("oversized output grew evidence or forged a phase")
	}
	output.Write([]byte("*** WARNING -- undefined macro\n"))
	if !output.diagnostics {
		t.Fatal("semantic warning ignored")
	}
}
