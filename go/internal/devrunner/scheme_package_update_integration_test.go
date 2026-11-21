// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build schemeintegration && !windows

package devrunner

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// Exercise the actual bootstrap entry with native packages and local Git
// transport. No real dependency is installed, removed or rebuilt by this test.
func TestSchemeToolCachedDependencyUpdate(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), schemePackageTestTimeout)
	defer cancel()
	root, repositories, prefix := t.TempDir(), t.TempDir(), t.TempDir()
	environment := Environment(map[string]string{
		"GERBIL_PATH": prefix, "GERBIL_LOADPATH": filepath.Join(prefix, "lib"), "GERBIL_BUILD_CORES": "4",
		"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.DevNull,
		"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "url.file://" + repositories + "/.insteadOf",
		"GIT_CONFIG_VALUE_0": "https://qualification.invalid/", "GIT_CONFIG_KEY_1": "protocol.file.allow", "GIT_CONFIG_VALUE_1": "always",
		"GIT_AUTHOR_NAME": "Package fixture", "GIT_COMMITTER_NAME": "Package fixture",
		"GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
	})
	// The caller may use an alternate publication index in a shared checkout.
	// Fixture Git repositories must own their own index and working tree.
	environment = slices.DeleteFunc(environment, func(entry string) bool {
		return strings.HasPrefix(entry, "GIT_INDEX_FILE=") || strings.HasPrefix(entry, "GIT_DIR=") ||
			strings.HasPrefix(entry, "GIT_WORK_TREE=") || strings.HasPrefix(entry, "GIT_COMMON_DIR=")
	})
	write := func(directory, name, body string) {
		t.Helper()
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(directory, name), []byte(body), 0755); err != nil {
			t.Fatal(err)
		}
	}
	git := func(directory string, args ...string) string {
		t.Helper()
		command := exec.CommandContext(ctx, "git", args...)
		command.Dir, command.Env = directory, environment
		output, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, output)
		}
		return strings.TrimSpace(string(output))
	}
	commit := func(directory string) string {
		t.Helper()
		git(directory, "add", ".")
		git(directory, "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
		return git(directory, "rev-parse", "HEAD")
	}
	repository := func(name, source, dependencies string) (string, string) {
		t.Helper()
		directory := filepath.Join(repositories, "team", name+".git")
		write(directory, "gerbil.pkg", fmt.Sprintf("(package: cache/%s depend: (%s))\n", name, dependencies))
		write(directory, "build.ss", "#!/usr/bin/env gxi\n(import :std/build-script)\n(defbuild-script '(\"value\"))\n")
		write(directory, "value.ss", source)
		git(directory, "init", "-q")
		return directory, commit(directory)
	}
	provider, oldProvider := repository("provider", "(export value) (def value 1)\n", "")
	write(provider, "value.ss", "(export value) (def value 2)\n")
	newProvider := commit(provider)
	lab, oldLab := repository("lab", "(import :cache/provider/value) (export value)\n", fmt.Sprintf("\"qualification.invalid/team/provider@%s\"", oldProvider))
	write(lab, "gerbil.pkg", fmt.Sprintf("(package: cache/lab depend: (\"qualification.invalid/team/provider@%s\"))\n", newProvider))
	newLab := commit(lab)
	_, sentinel := repository("sentinel", "(export value) (def value 99)\n", "")
	declare := func(labRevision string) {
		write(root, "gerbil.pkg", fmt.Sprintf("(package: cache/root depend: (\"qualification.invalid/team/lab@%s\" \"qualification.invalid/team/sentinel@%s\"))\n", labRevision, sentinel))
	}
	stages, err := Stages("bootstrap-scheme", "go")
	if err != nil {
		t.Fatal(err)
	}
	invoke := func(stage Stage) (Result, string) {
		t.Helper()
		artifacts := t.TempDir()
		result := runStage(ctx, root, artifacts, environment, stage)
		body, err := os.ReadFile(filepath.Join(artifacts, result.Log))
		if err != nil {
			t.Fatal(err)
		}
		return result, string(body)
	}
	bootstrap := func() string {
		t.Helper()
		result, body := invoke(stages[0])
		if result.Status != "PASS" {
			t.Fatalf("native bootstrap: %s\n%s", result.Error, body)
		}
		return body
	}
	declare(oldLab)
	bootstrap()
	untouched := filepath.Join(prefix, "lib", "cache", "sentinel", "value.o1")
	before, err := os.Stat(untouched)
	if err != nil {
		t.Fatal(err)
	}
	digest, err := fileSHA256(untouched)
	if err != nil {
		t.Fatal(err)
	}
	declare(newLab)
	installOnly := stages[0]
	installOnly.Args = append([]string(nil), installOnly.Args...)
	installOnly.Args[len(installOnly.Args)-1] = `(import :gerbil/tools/gxpkg) (with-pkg-build-env (for-each pkg-install (pgetq depend: (pkg-plist ".") '())))`
	rejected, diagnostic := invoke(installOnly)
	if rejected.Status != "FAIL" || rejected.ExitCode == nil || *rejected.ExitCode <= 0 ||
		!strings.Contains(diagnostic, "Package already installed with an incompatible tag") {
		t.Fatalf("install-only control missed the native tag conflict: %s\n%s", rejected.Status, diagnostic)
	}
	bootstrap()
	use, output := invoke(Stage{Name: "scheme-cache-use", Binary: schemeTool(), Args: []string{"interactive", "-e", `(import :cache/lab/value) (displayln "CACHE-VALUE=" value)`}})
	if use.Status != "PASS" || !strings.Contains(output, "CACHE-VALUE=2") {
		t.Fatalf("stale transitive dependency: %s\n%s", use.Error, output)
	}
	if hot := bootstrap(); strings.Contains(hot, "... compile ") {
		t.Fatalf("hot bootstrap recompiled package sources:\n%s", hot)
	}
	after, err := os.Stat(untouched)
	if err != nil {
		t.Fatal(err)
	}
	finalDigest, err := fileSHA256(untouched)
	if err != nil || digest != finalDigest || !before.ModTime().Equal(after.ModTime()) {
		t.Fatalf("unchanged package artifact was replaced: %v", err)
	}
	write(root, "gerbil.pkg", fmt.Sprintf("(package: cache/root depend: (\"qualification.invalid/team/lab@%s\" \"qualification.invalid/team/provider@%s\"))\n", newLab, oldProvider))
	conflict, output := invoke(stages[0])
	if conflict.Status != "FAIL" || conflict.ExitCode == nil || *conflict.ExitCode <= 0 ||
		!strings.Contains(output, "Package already installed with an incompatible tag") {
		t.Fatalf("conflicting transitive pins were silently accepted: %s\n%s", conflict.Status, output)
	}
}
