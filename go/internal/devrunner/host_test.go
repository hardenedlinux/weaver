// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHostedPreparationRejectsNormalDevelopment(t *testing.T) {
	t.Setenv("GITHUB_ACTIONS", "false")
	if err := PrepareHostedCI(io.Discard); err == nil {
		t.Fatal("implicit local privileged cleanup admitted")
	}
}

func TestHostedCleanupOnlyRemovesUnusedSDKs(t *testing.T) {
	root := t.TempDir()
	for _, path := range unusedHostedSDKs {
		if err := os.MkdirAll(filepath.Join(root, path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, path, "sdk"), []byte("unused"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, path := range []string{"nix/store/locked-sdk", "home/runner/.elan/pinned", "home/runner/work/weaver/source"} {
		if err := os.MkdirAll(filepath.Join(root, path), 0700); err != nil {
			t.Fatal(err)
		}
	}
	var log bytes.Buffer
	if err := removeHostedSDKs(root, &log); err != nil {
		t.Fatal(err)
	}
	for _, path := range unusedHostedSDKs {
		if _, err := os.Lstat(filepath.Join(root, path)); !os.IsNotExist(err) {
			t.Fatalf("unused SDK retained: %s: %v", path, err)
		}
		if !strings.Contains(log.String(), path) {
			t.Fatalf("cleanup omitted receipt: %s", path)
		}
	}
	for _, path := range []string{"nix/store/locked-sdk", "home/runner/.elan/pinned", "home/runner/work/weaver/source"} {
		if _, err := os.Stat(filepath.Join(root, path)); err != nil {
			t.Fatalf("required source/toolchain removed: %s: %v", path, err)
		}
	}
	if err := removeHostedSDKs(root, io.Discard); err != nil {
		t.Fatalf("already absent SDKs must be harmless: %v", err)
	}
}

func TestHostedCleanupDoesNotFollowSDKLink(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	sentinel := filepath.Join(outside, "preserve")
	if err := os.WriteFile(sentinel, []byte("required"), 0600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, unusedHostedSDKs[0])
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, path); err != nil {
		t.Fatal(err)
	}
	if err := removeHostedSDKs(root, io.Discard); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(sentinel); err != nil {
		t.Fatalf("cleanup followed SDK link: %v", err)
	}
}

func TestHostedCleanupRejectsAncestorLink(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "keep/lib/android"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "usr"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../keep", filepath.Join(root, "usr/local")); err != nil {
		t.Fatal(err)
	}
	if err := removeHostedSDKs(root, io.Discard); err == nil {
		t.Fatal("ancestor link redirected cleanup into required data")
	}
	if _, err := os.Stat(filepath.Join(root, "keep/lib/android")); err != nil {
		t.Fatal("redirected data removed")
	}
}
