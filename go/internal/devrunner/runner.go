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
	Name           string   `json:"name"`
	Status         string   `json:"status"`
	Binary         string   `json:"binary"`
	ResolvedBinary string   `json:"resolvedBinary,omitempty"`
	Args           []string `json:"args"`
	Log            string   `json:"log"`
	ExitCode       *int     `json:"exitCode,omitempty"`
	Error          string   `json:"error,omitempty"`
	Duration       string   `json:"duration"`
}
type Receipt struct {
	Revision string            `json:"revision,omitempty"`
	Status   string            `json:"status"`
	Root     string            `json:"root"`
	Started  string            `json:"started"`
	Stages   []Result          `json:"stages"`
	Mode     string            `json:"mode"`
	Inputs   map[string]string `json:"inputs"`
}

func FindRoot(start string) (string, error) {
	path, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		if regular(filepath.Join(path, "Cargo.toml")) && regular(filepath.Join(path, "go.work")) {
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

// Run retains independent logs and an atomically replaced receipt after every stage.
// Only fixed argument vectors are executed; no shell or command-string interpretation exists.
func Run(ctx context.Context, config Config, output io.Writer) (string, error) {
	root, err := FindRoot(config.Root)
	if err != nil {
		return "", err
	}
	goBinary := config.GoBinary
	if goBinary == "" {
		goBinary = filepath.Join(runtime.GOROOT(), "bin/go")
	}
	data := filepath.Join(root, ".cache")
	for _, name := range []string{"", "go-build-cache", "go-mod-cache", "go-tmp"} {
		if err := os.MkdirAll(filepath.Join(data, name), 0700); err != nil {
			return "", err
		}
	}
	directory, err := os.MkdirTemp(data, "verification-")
	if err != nil {
		return "", err
	}
	settings := map[string]string{
		"GOCACHE": filepath.Join(data, "go-build-cache"), "GOMODCACHE": filepath.Join(data, "go-mod-cache"),
		"GOTMPDIR": filepath.Join(data, "go-tmp"), "GOTOOLCHAIN": "local",
	}
	if config.Mode == "bootstrap" {
		// Prefetch the existing module requirements, without expanding workspace sums.
		// Verification itself continues to use the repository's Go workspace.
		settings["GOWORK"] = "off"
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
			fmt.Fprintf(output, "FAIL %s\nEvidence: %s\n", admission.Name, directory)
			return directory, errors.New("source does not match a committed revision")
		}
		fmt.Fprintf(output, "PASS %s\n", admission.Name)
	}
	failed := false
	if mode == "check-scheme" {
		result := schemeSourceCurrentness(directory, "linked-source-before")
		receipt.Stages = append(receipt.Stages, result)
		fmt.Fprintf(output, "%s %s\n", result.Status, result.Name)
		if result.Status != "PASS" {
			receipt.Status = "FAIL"
			if err := writeReceipt(directory, receipt); err != nil {
				return directory, err
			}
			return directory, errors.New("linked Scheme source admission failed")
		}
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
	if mode == "check-scheme" {
		result := schemeSourceCurrentness(directory, "linked-source-after")
		receipt.Stages = append(receipt.Stages, result)
		fmt.Fprintf(output, "%s %s\n", result.Status, result.Name)
		if result.Status != "PASS" {
			failed = true
		}
	}
	if mode == "bench" && !failed {
		if err := collectBenchmarks(root, directory, receipt.Started); err != nil {
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
		receipt.Status = "PASS"
		if failed {
			receipt.Status = "FAIL"
		}
	}
	if err := writeReceipt(directory, receipt); err != nil {
		return directory, err
	}
	fmt.Fprintf(output, "Evidence: %s\n", directory)
	if failed {
		return directory, errors.New("verification did not pass; retained stage logs and receipt.json")
	}
	return directory, nil
}
func runStage(ctx context.Context, root, directory string, environment []string, stage Stage) Result {
	if stage.Name == "scheme-unit-tests" {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 15*time.Second)
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
	cmd.Stdout = log
	cmd.Stderr = log
	err = cmd.Run()
	closeErr := log.Close()
	result.Duration = time.Since(started).String()
	if cmd.ProcessState != nil {
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
