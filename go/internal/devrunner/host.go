// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"
)

// These hosted-image SDKs are unrelated to the locked Nix, Rust, Go and Lean
// toolchains. Never accept caller-supplied cleanup paths or run this implicitly.
var unusedHostedSDKs = []string{
	"usr/local/lib/android",
	"usr/share/dotnet",
	"opt/ghc",
	"usr/local/.ghcup",
	"opt/hostedtoolcache/CodeQL",
}

// PrepareHostedCI is an explicit adapter for disposable GitHub-hosted Linux jobs.
// It is not part of local bootstrap/check/bench and never modifies dependency pins.
func PrepareHostedCI(output io.Writer) error {
	if runtime.GOOS != "linux" || os.Getenv("GITHUB_ACTIONS") != "true" ||
		os.Getenv("RUNNER_ENVIRONMENT") != "github-hosted" || os.Getenv("RUNNER_OS") != "Linux" || os.Geteuid() != 0 {
		return fmt.Errorf("host preparation requires an explicit privileged GitHub-hosted Linux job")
	}
	return removeHostedSDKs("/", output)
}

func removeHostedSDKs(directory string, output io.Writer) error {
	root, err := os.OpenRoot(directory)
	if err != nil {
		return err
	}
	defer root.Close()
	for _, path := range unusedHostedSDKs {
		parts := strings.Split(path, "/")
		for i := 1; i < len(parts); i++ {
			ancestor := strings.Join(parts[:i], "/")
			info, err := root.Lstat(ancestor)
			if os.IsNotExist(err) {
				break
			}
			if err != nil {
				return err
			}
			if info.Mode()&os.ModeSymlink != 0 {
				return fmt.Errorf("refuse hosted SDK ancestor link: %s", ancestor)
			}
		}
		// Root constrains resolution; an image's symlink cannot redirect deletion
		// outside the selected root. RemoveAll unlinks final symlinks themselves.
		if err := root.RemoveAll(path); err != nil {
			return fmt.Errorf("remove unused hosted SDK %s: %w", path, err)
		}
		if _, err := fmt.Fprintf(output, "Removed unused hosted SDK: /%s\n", path); err != nil {
			return err
		}
	}
	return nil
}
