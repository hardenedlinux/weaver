// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"github.com/HardenedLinux/weaver/go/internal/devrunner"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

func TestHeaderSealPairs(t *testing.T) {
	root, err := devrunner.FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	build := exec.CommandContext(t.Context(), "cargo", "bench", "-p", "weaver-execution", "--bench", "gateway", "--no-run", "--locked", "--offline", "--message-format=json-render-diagnostics")
	build.Dir, build.Stderr = root, os.Stderr
	executable, err := buildCargoExecutable(build, cargoTarget{Name: "gateway", Kind: "bench", Test: true, Optimized: true})
	if err != nil {
		t.Fatal(err)
	}
	image := filepath.Join(t.TempDir(), "header-seal")
	digest, err := publishProviderImage(executable, image)
	if err != nil {
		t.Fatal(err)
	}
	command := exec.CommandContext(t.Context(), image, "--weaver-header-seal")
	command.Dir = root
	data, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("header-seal experiment: %v: %s", err, data)
	}
	verified, err := os.Open(image)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.New()
	_, readErr := io.Copy(hash, verified)
	closeErr := verified.Close()
	if readErr != nil || closeErr != nil || hex.EncodeToString(hash.Sum(nil)) != digest {
		t.Fatal("captured image changed during benchmark", readErr, closeErr)
	}
	var output bytes.Buffer

	fmt.Fprintf(&output, "weaver-header-seal-image sha256=%s profile=release\n", digest)
	output.Write(data)
	if _, err := devrunner.ReadHeaderSealEvidence(&output, runtime.NumCPU()); err != nil {
		t.Fatal(err)
	}
	t.Logf("weaver-header-seal-image sha256=%s profile=release", digest)
	t.Log(string(data))
}
