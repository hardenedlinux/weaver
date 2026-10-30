package devrunner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

// This is a development load-path profile, never a Policy authority or a new VM.
type schemeImageProfile struct {
	Schema    string            `json:"schema"`
	CPUs      int               `json:"cpus"`
	Modules   map[string]string `json:"modules"`
	Excluded  map[string]string `json:"excluded"`
	Inputs    map[string]string `json:"inputs"`
	Artifacts map[string]string `json:"artifacts"`
	Tools     map[string]string `json:"tools"`
	Compiler  string            `json:"compiler"`
	Bindings  map[string]string `json:"bindings"`
	Overlay   string            `json:"overlay"`
}

func imageFileHash(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func environmentMap(environment []string) map[string]string {
	result := map[string]string{}
	for _, entry := range environment {
		key, value, ok := strings.Cut(entry, "=")
		if ok {
			result[key] = value
		}
	}
	return result
}

// SDK compiler discovery may return a bare command name. Resolve it using the
// build child's PATH and cwd, not the verifier parent's PATH or repository file.
// Inspection never invokes the tool or interprets command text.
func resolveImageTool(root, tool string, environment []string) (string, error) {
	if tool == "" {
		return "", errors.New("empty recorded image tool")
	}
	candidates := []string{tool}
	if !filepath.IsAbs(tool) && !strings.ContainsRune(tool, os.PathSeparator) {
		candidates = nil
		for _, directory := range filepath.SplitList(environmentMap(environment)["PATH"]) {
			candidates = append(candidates, filepath.Join(directory, tool))
		}
	}
	for _, candidate := range candidates {
		if !filepath.IsAbs(candidate) {
			candidate = filepath.Join(root, candidate)
		}
		info, err := os.Stat(candidate)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
			continue
		}
		resolved, err := filepath.EvalSymlinks(candidate)
		if err != nil {
			return "", err
		}
		return resolved, nil
	}
	return "", fmt.Errorf("recorded image tool %q is not executable in the build environment", tool)
}

func validModuleIdentity(identity string) bool {
	if identity == "" || filepath.IsAbs(identity) || strings.ContainsAny(identity, "\\\t\r\n\x00:") {
		return false
	}
	for _, part := range strings.Split(identity, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

func readModuleRegistry(data []byte) (map[string]string, error) {
	modules := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) != 2 || !validModuleIdentity(fields[0]) || !filepath.IsAbs(fields[1]) {
			return nil, errors.New("invalid Gerbil module registry entry")
		}
		if _, duplicate := modules[fields[0]]; duplicate {
			return nil, errors.New("duplicate module registry identity")
		}
		modules[fields[0]] = fields[1]
	}
	if len(modules) == 0 {
		return nil, errors.New("empty Gerbil module registry")
	}
	return modules, nil
}

// Opaque foreign leaves and macro-prelude-dependent sources keep their original
// compiler/link owner. False positives only reduce packaging, never admission.
func imageExclusion(source []byte) string {
	for _, token := range []string{"c-declare", "c-lambda", "macro-"} {
		if strings.Contains(string(source), token) {
			return "requires original foreign-code or macro-prelude options"
		}
	}
	return ""
}

func imageCompilerEnvironment(environment []string) ([]string, error) {
	host := ""
	switch runtime.GOARCH {
	case "arm64":
		host = "aarch64-apple-darwin"
	case "amd64":
		host = "x86_64-apple-darwin"
	default:
		return nil, errors.New("unsupported Darwin compiler host")
	}
	settings := environmentMap(environment)
	for key, value := range map[string]string{"HOST": host, "TARGET": host, "OPT_LEVEL": "0", "CARGO_CFG_TARGET_OS": "macos", "GERBIL_DYNAMIC_MODULE_OPT_LEVEL": "0"} {
		settings[key] = value
	}
	return Environment(settings), nil
}

func verifyImageFiles(files map[string]string) error {
	for path, expected := range files {
		actual, err := imageFileHash(path)
		if err != nil {
			return fmt.Errorf("dynamic image input changed: %s: %w", path, err)
		}
		if actual != expected {
			return fmt.Errorf("dynamic image input hash mismatch: %s", path)
		}
	}
	return nil
}

func prepareSchemeImages(ctx context.Context, root string, environment []string, log io.Writer) ([]string, schemeImageProfile, error) {
	profile := schemeImageProfile{Schema: "weaver.scheme-images.v1", CPUs: runtime.NumCPU(), Modules: map[string]string{}, Excluded: map[string]string{}, Inputs: map[string]string{}, Artifacts: map[string]string{}, Tools: map[string]string{}, Bindings: map[string]string{}}
	if runtime.GOOS != "darwin" {
		fmt.Fprintln(log, "Darwin dynamic image packaging is not applicable on this host")
		return environment, profile, nil
	}
	settings := environmentMap(environment)
	prefix := settings["GERBIL_PATH"]
	compiler := settings["WEAVER_CONTROL_SCHEME_COMPILER"]
	if !filepath.IsAbs(prefix) || !filepath.IsAbs(compiler) {
		return nil, profile, errors.New("isolated Scheme prefix and absolute compiler required")
	}
	prefix, err := filepath.EvalSymlinks(prefix)
	if err != nil {
		return nil, profile, err
	}
	output, err := os.MkdirTemp(prefix, "dynamic-images-*")
	if err != nil {
		return nil, profile, err
	}
	registry := filepath.Join(output, "registry.tsv")
	files, err := filepath.Glob(filepath.Join(root, "t", "*-test.ss"))
	if err != nil || len(files) == 0 {
		return nil, profile, errors.New("Scheme-owned test modules absent")
	}
	args := append([]string{"-e", "(dump-stack-trace? #f)", filepath.Join(root, "dev/scheme/module-inventory.ss")}, files...)
	inventoryEnv := maps.Clone(settings)
	inventoryEnv["WEAVER_MODULE_INVENTORY"] = registry
	command := exec.CommandContext(ctx, compiler, args...)
	command.Dir = root
	command.Env = Environment(inventoryEnv)
	command.Stdout = log
	command.Stderr = log
	if err := runSchemeInventory(ctx, command, 15*time.Second); err != nil {
		return nil, profile, fmt.Errorf("module inventory: %w", err)
	}
	data, err := os.ReadFile(registry)
	if err != nil {
		return nil, profile, err
	}
	modules, err := readModuleRegistry(data)
	if err != nil {
		return nil, profile, err
	}
	byPath := map[string]string{}
	for identity, path := range modules {
		if filepath.Ext(path) != ".o1" {
			profile.Excluded[identity] = "not a first-generation dynamic object"
			continue
		}
		if filepath.Base(path) != filepath.Base(identity)+".o1" {
			return nil, profile, errors.New("registry identity does not match dynamic linker filename")
		}
		source := strings.TrimSuffix(path, ".o1") + ".scm"
		body, err := os.ReadFile(source)
		if err != nil {
			return nil, profile, err
		}
		for _, input := range []string{source, path} {
			hash, err := imageFileHash(input)
			if err != nil {
				return nil, profile, err
			}
			profile.Inputs[input] = hash
		}
		if reason := imageExclusion(body); reason != "" {
			profile.Excluded[identity] = reason
			continue
		}
		if _, duplicate := byPath[path]; duplicate {
			return nil, profile, errors.New("ambiguous original module path")
		}
		byPath[path] = identity
		profile.Modules[identity] = path
	}
	paths := make([]string, 0, len(byPath))
	for path := range byPath {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	if len(paths) == 0 {
		return nil, profile, errors.New("no eligible dynamic modules")
	}
	inventory := filepath.Join(output, "inputs.txt")
	if err := os.WriteFile(inventory, []byte(strings.Join(paths, "\n")+"\n"), 0600); err != nil {
		return nil, profile, err
	}
	compilerEnv, err := imageCompilerEnvironment(environment)
	if err != nil {
		return nil, profile, err
	}
	command = exec.CommandContext(ctx, "cargo", "run", "--locked", "--offline", "-p", "weaver-policy-ffi", "--example", "module_images", "--", compiler, inventory, output)
	command.Dir = root
	command.Env = compilerEnv
	command.Stdout = log
	command.Stderr = log
	if err := command.Run(); err != nil {
		return nil, profile, err
	}
	toolData, err := os.ReadFile(filepath.Join(output, "tools.txt"))
	if err != nil {
		return nil, profile, err
	}
	roles := map[string]bool{}
	for _, tool := range strings.Split(strings.TrimSpace(string(toolData)), "\n") {
		role, program, ok := strings.Cut(tool, "\t")
		if !ok || roles[role] || (role != "gsc" && role != "c-compiler" && role != "packager") {
			return nil, profile, errors.New("invalid SDK tool receipt")
		}
		roles[role] = true
		resolved, err := resolveImageTool(root, program, compilerEnv)
		if err != nil {
			return nil, profile, err
		}
		hash, err := imageFileHash(resolved)
		if err != nil {
			return nil, profile, err
		}
		profile.Tools[resolved] = hash
		if role == "c-compiler" {
			if profile.Compiler != "" {
				return nil, profile, errors.New("ambiguous SDK C compiler")
			}
			profile.Compiler = resolved
		}
	}
	if profile.Compiler == "" || len(roles) != 3 {
		return nil, profile, errors.New("SDK C compiler receipt absent")
	}
	data, err = os.ReadFile(filepath.Join(output, "bundles.tsv"))
	if err != nil {
		return nil, profile, err
	}
	profile.Overlay = filepath.Join(output, "overlay")
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		parts := strings.Split(line, "\t")
		if len(parts) != 2 {
			return nil, profile, errors.New("invalid SDK bundle receipt")
		}
		identity, known := byPath[parts[0]]
		if !known {
			return nil, profile, errors.New("bundle contains an unregistered module")
		}
		if _, duplicate := profile.Bindings[identity]; duplicate {
			return nil, profile, errors.New("duplicate bundle binding")
		}
		image, err := filepath.EvalSymlinks(parts[1])
		if err != nil {
			return nil, profile, err
		}
		relative, err := filepath.Rel(output, image)
		if err != nil || strings.HasPrefix(relative, "..") || filepath.IsAbs(relative) {
			return nil, profile, errors.New("SDK bundle outside isolated image directory")
		}
		alias := filepath.Join(profile.Overlay, identity+".o1")
		if err := os.MkdirAll(filepath.Dir(alias), 0700); err != nil {
			return nil, profile, err
		}
		if err := os.Symlink(image, alias); err != nil {
			return nil, profile, err
		}
		hash, err := imageFileHash(image)
		if err != nil {
			return nil, profile, err
		}
		profile.Artifacts[image] = hash
		profile.Bindings[identity] = image
	}
	if len(profile.Bindings) == 0 {
		return nil, profile, errors.New("SDK selected no dynamic images")
	}
	if err := verifyImageFiles(profile.Inputs); err != nil {
		return nil, profile, err
	}
	data, err = json.MarshalIndent(profile, "", "  ")
	if err != nil {
		return nil, profile, err
	}
	if err := os.WriteFile(filepath.Join(output, "profile.json"), data, 0600); err != nil {
		return nil, profile, err
	}
	fmt.Fprintf(log, "DYNAMIC-IMAGES logical-modules=%d physical-images=%d original-option-leaves=%d cpus=%d\n", len(profile.Bindings), len(profile.Artifacts), len(profile.Excluded), profile.CPUs)
	settings["GERBIL_LOADPATH"] = profile.Overlay + string(os.PathListSeparator) + settings["GERBIL_LOADPATH"]
	return Environment(settings), profile, nil
}

func runSchemeImageStage(ctx context.Context, root, directory string, environment []string, stage Stage) (Result, []string) {
	result := Result{Name: stage.Name, Binary: stage.Binary, Status: "FAIL", Log: stage.Name + ".log"}
	started := time.Now()
	log, err := os.OpenFile(filepath.Join(directory, result.Log), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		result.Error = err.Error()
		return result, environment
	}
	updated, _, buildErr := prepareSchemeImages(ctx, root, environment, log)
	err = errors.Join(buildErr, log.Close())
	result.Duration = time.Since(started).String()
	if err != nil {
		result.Error = err.Error()
		return result, environment
	}
	result.Status = "PASS"
	return result, updated
}
