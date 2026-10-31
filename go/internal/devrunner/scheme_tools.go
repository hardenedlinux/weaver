package devrunner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func fileSHA256(path string) (string, error) {
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

// Resolve the selected SDK tool through the child's PATH and working directory.
// Tool selection is data; it is never interpreted as a shell command.
func resolveBuildTool(root, tool string, environment []string) (string, error) {
	if tool == "" {
		return "", errors.New("empty recorded build tool")
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
	return "", fmt.Errorf("recorded build tool %q is not executable in the build environment", tool)
}

// Discover the standard SDK home through the selected compiler during build
// preparation. This is tool discovery, never a runtime Scheme IPC path.
func schemeHome(ctx context.Context, root, compiler string, environment []string) (string, error) {
	home := environmentMap(environment)["GERBIL_HOME"]
	if home == "" {
		command := exec.CommandContext(ctx, compiler, "-e", "(displayln (gerbil-home))")
		command.Dir, command.Env = root, environment
		data, err := command.Output()
		if err != nil {
			return "", fmt.Errorf("discover Gerbil SDK home: %w", err)
		}
		home = strings.TrimSuffix(string(data), "\n")
	}
	if !filepath.IsAbs(home) || strings.ContainsAny(home, "\r\n") {
		return "", errors.New("Gerbil SDK home must be one absolute directory")
	}
	core := filepath.Join(home, "lib", "gerbil", "core.ssi")
	info, err := os.Stat(core)
	if err != nil || !info.Mode().IsRegular() {
		return "", errors.New("selected Gerbil SDK home has no core interface")
	}
	return home, nil
}
