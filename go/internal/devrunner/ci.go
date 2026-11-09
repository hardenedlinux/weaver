// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

// PrepareCITools installs host packages only on disposable GitHub-hosted jobs.
// Test selection, dependency fetching and execution remain separate Go stages.
func PrepareCITools(ctx context.Context, output io.Writer) error {
	if os.Getenv("GITHUB_ACTIONS") != "true" || os.Getenv("RUNNER_ENVIRONMENT") != "github-hosted" {
		return fmt.Errorf("CI package preparation requires a disposable GitHub-hosted job")
	}
	suite := os.Getenv("WEAVER_VERIFY_SUITE")
	switch suite {
	case "check-rust", "check-go", "check-scheme", "check-policy", "check-architecture", "bench":
	default:
		return fmt.Errorf("unsupported CI suite %q", suite)
	}
	if os.Getenv("RUNNER_TEMP") == "" || os.Getenv("GITHUB_PATH") == "" {
		return fmt.Errorf("missing disposable runner paths")
	}
	run := func(binary string, args ...string) error {
		command := exec.CommandContext(ctx, binary, args...)
		command.Stdout, command.Stderr = output, output
		if err := command.Run(); err != nil {
			return fmt.Errorf("CI package command %s: %w", binary, err)
		}
		return nil
	}
	switch runtime.GOOS {
	case "linux":
		self, err := os.Executable()
		if err != nil {
			return err
		}
		if err := run("sudo", "--preserve-env=GITHUB_ACTIONS,RUNNER_ENVIRONMENT,RUNNER_OS", self, "prepare-ci-host"); err != nil {
			return err
		}
		if err := run("sudo", "apt-get", "-o", "Acquire::http::Timeout=30", "-o", "Acquire::https::Timeout=30", "update"); err != nil {
			return err
		}
		packages := []string{"apt-get", "install", "-y", "--no-install-recommends", "build-essential", "ca-certificates", "pkg-config", "libssl-dev", "zlib1g-dev", "protobuf-compiler"}
		if suite == "check-policy" {
			packages = append(packages, "elan", "cvc5", "zstd")
		}
		if err := run("sudo", packages...); err != nil {
			return err
		}
	case "darwin":
		packages := []string{"install", "pkg-config", "openssl@3", "zlib", "protobuf"}
		if suite == "check-policy" {
			packages = append(packages, "elan", "cvc5")
		}
		if err := run("brew", packages...); err != nil {
			return err
		}
	default:
		return fmt.Errorf("unsupported CI host %s", runtime.GOOS)
	}
	// rustup consumes the root toolchain manifest; no Nix evaluation is involved.
	if err := run("rustup", "show", "active-toolchain"); err != nil {
		return err
	}
	tools := filepath.Join(os.Getenv("RUNNER_TEMP"), "weaver-ci-tools")
	if err := os.MkdirAll(tools, 0700); err != nil {
		return err
	}
	command := exec.CommandContext(ctx, filepath.Join(runtime.GOROOT(), "bin/go"), "install", "github.com/rhysd/actionlint/cmd/actionlint@v1.7.12")
	command.Env = Environment(map[string]string{"GOBIN": tools})
	command.Stdout, command.Stderr = output, output
	if err := command.Run(); err != nil {
		return err
	}
	if suite == "check-policy" {
		if err := run("npm", "install", "--global", "@informalsystems/quint@0.30.0"); err != nil {
			return err
		}
	}
	path, err := os.OpenFile(os.Getenv("GITHUB_PATH"), os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, written := fmt.Fprintln(path, tools)
	return errors.Join(written, path.Close())
}
