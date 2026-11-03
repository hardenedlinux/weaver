// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && darwin

package dev

import "testing"

// Explicit opt-in image experiment, excluded from the TestProvider assurance set.
// ABC/CBA balances order; neither fresh files nor re-signing flush host caches.
func TestDarwinStartupImageComparison(t *testing.T) {
	order := []string{"linker", "resigned", "stripped", "stripped", "resigned", "linker"}
	for _, variant := range order {
		t.Run(variant, func(t *testing.T) {
			path := copyStartupImage(t)
			if variant == "stripped" {
				t.Logf("strip: %s", tool(t, "/usr/bin/strip", "-S", "-x", path))
			}
			if variant != "linker" {
				t.Logf("sign: %s", tool(t, "/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "weaver.startup.experiment", path))
			}
			t.Logf("verify: %s", tool(t, "/usr/bin/codesign", "--verify", "--strict", path))
			checkStartupImage(t, path)
		})
	}
}
