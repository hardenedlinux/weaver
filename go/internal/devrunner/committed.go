// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// Compare actual source bytes to committed blobs. Git status alone can hide
// changes through index flags or ignored, untracked compiler inputs.
func committedSource(ctx context.Context, root, directory, name, expected string, inputs map[string]string) (result Result, revision string) {
	result = Result{Name: name, Binary: "git", Args: []string{"--no-replace-objects", "cat-file", "--batch"}, Status: "FAIL", Log: name + ".log"}
	var diagnostics strings.Builder
	defer func() {
		if err := os.WriteFile(filepath.Join(directory, result.Log), []byte(diagnostics.String()), 0600); err != nil {
			result.Status, result.Error = "FAIL", err.Error()
		}
	}()
	head := exec.CommandContext(ctx, "git", "--no-replace-objects", "rev-parse", "--verify", "HEAD")
	head.Dir = root
	data, err := head.Output()
	if err != nil {
		result.Error = "source revision unavailable"
		fmt.Fprintln(&diagnostics, result.Error)
		return
	}
	revision = strings.TrimSpace(string(data))
	fmt.Fprintln(&diagnostics, "revision="+revision)
	if expected != "" && revision != expected {
		result.Error = "source revision changed during verification"
		fmt.Fprintln(&diagnostics, result.Error)
		return
	}
	paths := make([]string, 0, len(inputs))
	for path := range inputs {
		if strings.ContainsAny(path, "\r\n\x00") {
			result.Error = "unsupported source path framing"
			fmt.Fprintln(&diagnostics, result.Error)
			return
		}
		paths = append(paths, path)
	}
	slices.Sort(paths)
	var requests strings.Builder
	for _, path := range paths {
		fmt.Fprintf(&requests, "%s:%s\n", revision, path)
	}
	cmd := exec.CommandContext(ctx, "git", "--no-replace-objects", "cat-file", "--batch")
	cmd.Dir, cmd.Stdin = root, strings.NewReader(requests.String())
	result.ResolvedBinary = cmd.Path
	if resolved, err := filepath.EvalSymlinks(cmd.Path); err == nil {
		result.ResolvedBinary = resolved
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		result.Error = err.Error()
		return
	}
	if err = cmd.Start(); err != nil {
		result.Error = err.Error()
		return
	}
	reader := bufio.NewReader(pipe)
	failed := false
	for _, path := range paths {
		header, err := reader.ReadString('\n')
		fields := strings.Fields(header)
		if err != nil || len(fields) != 3 || fields[1] != "blob" {
			failed = true
			fmt.Fprintln(&diagnostics, "missing or invalid committed source: "+path)
			break
		}
		size, err := strconv.ParseInt(fields[2], 10, 64)
		if err != nil || size < 0 {
			failed = true
			fmt.Fprintln(&diagnostics, "invalid committed blob framing")
			break
		}
		digest := sha256.New()
		_, copied := io.CopyN(digest, reader, size)
		separator, separated := reader.ReadByte()
		if copied != nil || separated != nil || separator != '\n' {
			failed = true
			fmt.Fprintln(&diagnostics, "incomplete committed blob: "+path)
			break
		}
		if fmt.Sprintf("%x", digest.Sum(nil)) != inputs[path] {
			failed = true
			fmt.Fprintln(&diagnostics, "source differs from commit: "+path)
		}
	}
	_, drain := io.Copy(io.Discard, reader)
	wait := cmd.Wait()
	if failed || drain != nil || wait != nil {
		result.Error = "source inputs do not match the committed revision"
		fmt.Fprintln(&diagnostics, result.Error, stderr.String())
		return
	}
	result.Status = "PASS"
	fmt.Fprintf(&diagnostics, "PASS committed inputs=%d\n", len(inputs))
	return
}
