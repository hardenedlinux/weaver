// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
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
