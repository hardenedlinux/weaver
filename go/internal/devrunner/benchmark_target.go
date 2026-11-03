// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"path/filepath"
)

// Cargo owns target selection, including environment and workspace configuration.
// Do not infer a second output location from the source checkout.
func cargoBenchmarkTarget(ctx context.Context, root string, environment []string) (string, error) {
	command := exec.CommandContext(ctx, "cargo", "metadata", "--format-version=1", "--no-deps", "--locked", "--offline")
	command.Dir, command.Env = root, environment
	data, err := command.Output()
	if err != nil {
		return "", err
	}
	var metadata struct {
		TargetDirectory string `json:"target_directory"`
	}
	if err := json.Unmarshal(data, &metadata); err != nil {
		return "", err
	}
	if !filepath.IsAbs(metadata.TargetDirectory) {
		return "", errors.New("Cargo metadata omitted absolute target directory")
	}
	return metadata.TargetDirectory, nil
}

func collectCargoBenchmarks(ctx context.Context, root, directory, started string, environment []string, selected ...string) error {
	target, err := cargoBenchmarkTarget(ctx, root, environment)
	if err != nil {
		return err
	}
	return collectBenchmarks(target, directory, started, selected...)
}
