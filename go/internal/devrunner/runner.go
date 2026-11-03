// Package devrunner owns the shell-free development verification entrypoint.
package devrunner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"time"
)

type Config struct {
	Root, GoBinary, Mode string
	RequireClean         bool
}
type Stage struct {
	Name, Binary string
	Args         []string
}
type Result struct {
	Contention         *ContentionEvidence `json:"contention,omitempty"`
	Name               string              `json:"name"`
	Status             string              `json:"status"`
	Binary             string              `json:"binary"`
	ResolvedBinary     string              `json:"resolvedBinary,omitempty"`
	Args               []string            `json:"args"`
	Log                string              `json:"log"`
	OutputSHA256       string              `json:"outputSha256,omitempty"`
	FailureTail        string              `json:"failureTail,omitempty"`
	Details            string              `json:"details,omitempty"`
	ExitCode           *int                `json:"exitCode,omitempty"`
	Error              string              `json:"error,omitempty"`
	Duration           string              `json:"duration"`
	SchemeTiming       *SchemeTiming       `json:"schemeTiming,omitempty"`
	UserCPU            string              `json:"userCpu,omitempty"`
	SystemCPU          string              `json:"systemCpu,omitempty"`
	GoBenchmarks       []GoBenchmark       `json:"goBenchmarks,omitempty"`
	PipelineBenchmarks []PipelineBenchmark `json:"pipelineBenchmarks,omitempty"`
	BenchmarkSummary   string              `json:"benchmarkSummary,omitempty"`
	Lean               *LeanEvidence       `json:"lean,omitempty"`
}
type Receipt struct {
	Revision           string            `json:"revision,omitempty"`
	Status             string            `json:"status"`
	Root               string            `json:"root"`
	Started            string            `json:"started"`
	Stages             []Result          `json:"stages"`
	Mode               string            `json:"mode"`
	Inputs             map[string]string `json:"inputs"`
	LinkedSourceHeads  map[string]string `json:"linkedSourceHeads,omitempty"`
	LinkedSourceSHA256 string            `json:"linkedSourceSha256,omitempty"`
	ProofReferences    []ProofReference  `json:"proofReferences,omitempty"`
}

func FindRoot(start string) (string, error) {
	path, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		if regular(filepath.Join(path, "Cargo.toml")) && regular(filepath.Join(path, "go", "go.mod")) {
			return path, nil
		}
		parent := filepath.Dir(path)
		if parent == path {
			return "", errors.New("repository workspace not found")
		}
		path = parent
	}
}
func regular(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// Run uses temporary stage logs and replaces one compact result per mode.
// Only fixed argument vectors are executed; no shell or command-string interpretation exists.
func Run(ctx context.Context, config Config, output io.Writer) (report string, runErr error) {
	root, err := FindRoot(config.Root)
	if err != nil {
		return "", err
	}
	goBinary := config.GoBinary
	if goBinary == "" {
		goBinary = filepath.Join(runtime.GOROOT(), "bin/go")
	}
	data := filepath.Join(root, ".cache")
	for _, name := range []string{"", "go-build-cache", "go-mod-cache"} {
		if err := os.MkdirAll(filepath.Join(data, name), 0700); err != nil {
			return "", err
		}
	}
	directory, err := os.MkdirTemp("", "weaver-verification-")
	if err != nil {
		return "", err
	}
	defer func() {
		path, err := publishLatestResult(root, directory, config.Mode, runErr)
		report = path
		runErr = errors.Join(runErr, err)
	}()
	settings := map[string]string{
		"GOCACHE": filepath.Join(data, "go-build-cache"), "GOMODCACHE": filepath.Join(data, "go-mod-cache"),
		"GOTMPDIR": directory, "GOTOOLCHAIN": "local",
	}
	environment := Environment(settings)
	mode := config.Mode
	if mode == "" {
		mode = "check"
	}
	stages, err := Stages(mode, goBinary)
	if err != nil {
		return directory, err
	}
	inputs, err := SourceInputs(root)
	if err != nil {
		return directory, err
	}
	receipt := Receipt{Status: "RUNNING", Root: root, Mode: mode, Inputs: inputs, Started: time.Now().UTC().Format(time.RFC3339Nano)}
	if config.RequireClean {
		admission, revision := committedSource(ctx, root, directory, "committed-source-before", "", inputs)
		receipt.Revision = revision
		receipt.Stages = append(receipt.Stages, admission)
		if admission.Status != "PASS" {
			receipt.Status = "FAIL"
			if err := writeReceipt(directory, receipt); err != nil {
				return directory, err
			}
			fmt.Fprintf(output, "FAIL %s\n", admission.Name)
			return directory, errors.New("source does not match a committed revision")
		}
		fmt.Fprintf(output, "PASS %s\n", admission.Name)
	}
	if err := writeReceipt(directory, receipt); err != nil {
		return directory, err
	}
	failed := false
	if mode == "check-scheme" || mode == "bench-runtime" {
		// These are Weaver's FFI link inputs and host resource policy, not
		// a Scheme package installer or SDK discovery layer.
		metadata := filepath.Join(directory, "pkgconfig")
		settings["WEAVER_POLICY_PKG_CONFIG"] = filepath.Join(metadata, "weaver-policy-ffi.pc")
		settings["PKG_CONFIG_PATH"] = metadata
		if inherited := os.Getenv("PKG_CONFIG_PATH"); inherited != "" {
			settings["PKG_CONFIG_PATH"] += string(os.PathListSeparator) + inherited
		}
		settings["GERBIL_BUILD_CORES"] = strconv.Itoa(runtime.NumCPU())
		environment = Environment(settings)
	}
	for _, stage := range stages {
		if ctx.Err() != nil {
			receipt.Status = "CANCELLED"
			failed = true
			break
		}
		result := runStage(ctx, root, directory, environment, stage)
		receipt.Stages = append(receipt.Stages, result)
		if result.Status != "PASS" {
			failed = true
		}
		if err := writeReceipt(directory, receipt); err != nil {
			return directory, err
		}
		fmt.Fprintf(output, "%s %s\n", result.Status, result.Name)
	}
	if mode != "generate-rpc" {
		current := sourceCurrentness(root, directory, inputs)
		receipt.Stages = append(receipt.Stages, current)
		if current.Status != "PASS" {
			failed = true
		}
		fmt.Fprintf(output, "%s %s\n", current.Status, current.Name)
	}
	if mode == "bench" && !failed {
		if err := collectCargoBenchmarks(ctx, root, directory, receipt.Started, environment); err != nil {
			failed = true
			fmt.Fprintf(output, "FAIL benchmark artifacts: %v\n", err)
		}
	}
	if config.RequireClean {
		admission, _ := committedSource(ctx, root, directory, "committed-source-after", receipt.Revision, inputs)
		receipt.Stages = append(receipt.Stages, admission)
		if admission.Status != "PASS" {
			failed = true
		}
		fmt.Fprintf(output, "%s %s\n", admission.Status, admission.Name)
	}
	if ctx.Err() != nil {
		receipt.Status = "CANCELLED"
		failed = true
	}
	if receipt.Status != "CANCELLED" {
		if refs, err := proofReferences(root, receipt.Stages); err != nil {
			receipt.Stages = append(receipt.Stages, Result{Name: "proof-references", Status: "FAIL", Error: err.Error()})
			failed = true
		} else {
			receipt.ProofReferences = refs
		}
		receipt.Status = "PASS"
		if failed {
			receipt.Status = "FAIL"
		}
	}
	if err := writeReceipt(directory, receipt); err != nil {
		return directory, err
	}
	fmt.Fprintf(output, "Result: %s\n", latestResultPath(root, mode))
	if failed {
		return directory, errors.New("verification did not pass; see the latest structured result")
	}
	return directory, nil
}
func runStage(ctx context.Context, root, directory string, environment []string, stage Stage) Result {
	return runStageCapture(ctx, root, directory, environment, stage, true)
}

// The direct-file arm is retained solely for paired tests of the historical
// output boundary. Both arms use the same public command and admission rules.
func runStageCapture(ctx context.Context, root, directory string, environment []string, stage Stage, streamSchemeOutput bool) Result {
	return runStageObserved(ctx, root, directory, environment, stage, streamSchemeOutput, nil)
}

// Package functionality has a whole-suite budget; native Runtime is measured separately.
const schemePackageTestTimeout = time.Minute

func runStageObserved(ctx context.Context, root, directory string, environment []string, stage Stage, streamSchemeOutput bool, onStart func(int)) Result {
	tests := ""
	switch stage.Name {
	case "scheme-unit-tests":
		tests = "t"
	case "scheme-source-integration-tests":
		tests = "t/integration"
	}
	if tests != "" {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, schemePackageTestTimeout)
		defer cancel()
	}

	result := Result{Name: stage.Name, Status: "FAIL", Binary: stage.Binary, Args: stage.Args, Log: stage.Name + ".log"}
	started := time.Now()
	log, err := os.OpenFile(filepath.Join(directory, result.Log), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	cmd := exec.CommandContext(ctx, stage.Binary, stage.Args...)
	result.ResolvedBinary = cmd.Path
	if resolved, err := filepath.EvalSymlinks(cmd.Path); err == nil {
		result.ResolvedBinary = resolved
	}
	cmd.Dir = root
	cmd.Env = environment
	var output io.Writer = log
	var observation *schemeOutput
	if tests != "" && streamSchemeOutput {
		observation = &schemeOutput{destination: log, started: started}
		output = observation
	}
	cmd.Stdout = output
	cmd.Stderr = output
	err = cmd.Start()
	if err == nil {
		if onStart != nil {
			onStart(cmd.Process.Pid)
		}
		err = cmd.Wait()
	}
	finished := time.Now()
	if observation != nil {
		result.SchemeTiming = observation.timing(finished)
	}
	closeErr := log.Close()
	if source := leanSource(stage); source != "" && closeErr == nil {
		var proofErr error
		result.Lean, proofErr = readLeanEvidence(root, source, filepath.Join(directory, result.Log))
		err = errors.Join(err, proofErr)
	}
	if stage.Name == "runtime-projection-benchmark" && err == nil && closeErr == nil {
		result.GoBenchmarks, err = readGoBenchmarks(filepath.Join(directory, result.Log), runtime.NumCPU(), sourceAdmissionBenchmarks...)
	}
	if stage.Name == "published-pipeline-benchmark" && err == nil && closeErr == nil {
		result.PipelineBenchmarks, err = readPipelineBenchmarks(filepath.Join(directory, result.Log), runtime.NumCPU(), "BenchmarkGatewayPublishedPipeline/registered")
		result.Details = "Real Go/Cedar/Rust path; Scheme preparation excluded, not a latency qualification."
	}
	if stage.Name == "execution-contention-pair" && err == nil && closeErr == nil {
		result.Contention, err = readContentionEvidence(filepath.Join(directory, result.Log))
		result.Details = "Five lock profiles, six complete ABBA blocks each, one optimized immutable benchmark image; intervals overlap."
	}
	if stage.Name == "execution-streaming-pair" && err == nil && closeErr == nil {
		result.PipelineBenchmarks, err = readStreamingPairBenchmarks(filepath.Join(directory, result.Log), runtime.NumCPU())
		result.Details = "Six complete same-image ABBA blocks, Arrow rows=1 versus rows=32; not a before/after implementation speedup."
	}
	if stage.Name == "runtime-pipeline-benchmark" && err == nil && closeErr == nil {
		result.PipelineBenchmarks, err = readPipelineBenchmarks(filepath.Join(directory, result.Log), runtime.NumCPU())
		result.Details = "Complete functional pipeline samples; no end-to-end speedup or non-regression qualification."
	}
	if stage.Name == "grpc-benchmark" && err == nil && closeErr == nil {
		result.GoBenchmarks, err = readGoBenchmarks(filepath.Join(directory, result.Log), runtime.NumCPU())
	}
	if (stage.Name == "storage-final-benchmark" || stage.Name == "telemetry-benchmark" || stage.Name == "execution-policy-benchmark" || stage.Name == "execution-ledger-benchmark" || stage.Name == "execution-provider-benchmark" || stage.Name == "execution-encoding-benchmark") && err == nil && closeErr == nil {
		cases := storageBenchmarkCases
		if stage.Name == "execution-encoding-benchmark" {
			cases = []string{"server_encoding_guard_hold/inside", "server_encoding_guard_hold/outside"}
		}
		if stage.Name == "execution-provider-benchmark" {
			cases = []string{"execution_https_guarded_sse_three_events"}
		}
		if stage.Name == "execution-ledger-benchmark" {
			cases = []string{"ledger_provider_release/1", "ledger_provider_release/8", "ledger_provider_release/32"}
		}
		if stage.Name == "execution-policy-benchmark" {
			cases = []string{"policy_context_json_local", "policy_context_literal_local", "policy_context_json_shared", "policy_context_literal_shared"}
		}
		if stage.Name == "telemetry-benchmark" {
			cases = nil
			for _, name := range rustBenchmarkCases {
				if owner, _ := benchmarkPackage(name); owner == "weaver-telemetry" {
					cases = append(cases, name)
				}
			}
		}
		err = collectCargoBenchmarks(ctx, root, directory, started.UTC().Format(time.RFC3339Nano), environment, cases...)
		if err == nil {
			var data []byte
			data, err = os.ReadFile(filepath.Join(directory, "benchmark-summary.org"))
			result.BenchmarkSummary = string(data)
		}
	}
	if tests != "" && err == nil {
		err = validateSchemeResult(root, tests, filepath.Join(directory, result.Log))
		if ctx.Err() != nil {
			err = errors.Join(err, ctx.Err())
		}
	}
	result.Duration = finished.Sub(started).String()
	if cmd.ProcessState != nil {
		result.UserCPU = cmd.ProcessState.UserTime().String()
		result.SystemCPU = cmd.ProcessState.SystemTime().String()
		code := cmd.ProcessState.ExitCode()
		result.ExitCode = &code
	}
	if err == nil && closeErr == nil {
		result.Status = "PASS"
	} else {
		result.Error = fmt.Sprint(errors.Join(err, closeErr))
	}
	return result
}
func writeReceipt(directory string, receipt Receipt) error {
	data, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return err
	}
	temporary := filepath.Join(directory, "receipt.pending")
	if err := os.WriteFile(temporary, append(data, '\n'), 0600); err != nil {
		return err
	}
	return os.Rename(temporary, filepath.Join(directory, "receipt.json"))
}

// Environment replaces keys rather than relying on duplicate environment ordering.
func Environment(overrides map[string]string) []string {
	values := map[string]string{}
	for _, entry := range os.Environ() {
		for i := 0; i < len(entry); i++ {
			if entry[i] == '=' {
				values[entry[:i]] = entry[i+1:]
				break
			}
		}
	}
	for key, value := range overrides {
		values[key] = value
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	env := make([]string, 0, len(keys))
	for _, key := range keys {
		env = append(env, key+"="+values[key])
	}
	return env
}
