// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"bytes"
	"fmt"
	"github.com/HardenedLinux/weaver/go/internal/devrunner"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestContentionPairs(t *testing.T) {
	root, err := devrunner.FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	build := exec.CommandContext(t.Context(), "cargo", "bench", "-p", "weaver-ledger", "--bench", "gateway", "--no-run", "--locked", "--offline", "--message-format=json-render-diagnostics")
	build.Dir, build.Stderr = root, os.Stderr
	executable, err := buildCargoExecutable(build, cargoTarget{Name: "gateway", Kind: "bench", Test: true, Optimized: true})
	if err != nil {
		t.Fatal(err)
	}
	image := filepath.Join(t.TempDir(), "ledger-contention")
	digest, err := publishProviderImage(executable, image)
	if err != nil {
		t.Fatal(err)
	}
	command := exec.CommandContext(t.Context(), image, "--weaver-contention")
	command.Dir = root
	data, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("contention experiment: %v: %s", err, data)
	}
	var output bytes.Buffer
	fmt.Fprintf(&output, "weaver-contention-image sha256=%s profile=release\n", digest)
	output.Write(data)
	evidence, err := devrunner.ReadContentionEvidence(&output)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("weaver-contention-image sha256=%s profile=release", evidence.ImageSHA256)
	t.Log(string(data))
}
