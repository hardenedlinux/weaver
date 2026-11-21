// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"maps"
	"os"
	"path/filepath"
	"testing"
)

// Reproduce the verification source inventory without materializing generated
// run artifacts or depending on Git and network access.
func TestSourceInputsWithoutGeneratedArtifacts(t *testing.T) {
	working, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(working)
	if err != nil {
		t.Fatal(err)
	}
	inputs, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	isolated := copyVerificationInputs(t, root, inputs)
	actual, err := SourceInputs(isolated)
	if err != nil {
		t.Fatalf("source inventory requires generated run artifacts: %v", err)
	}
	if !maps.Equal(inputs, actual) {
		t.Fatal("copied source inventory changed")
	}
}

func copyVerificationInputs(t testing.TB, root string, inputs map[string]string) string {
	t.Helper()
	isolated := t.TempDir()
	for path := range inputs {
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(path)))
		if err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(isolated, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, body, 0600); err != nil {
			t.Fatal(err)
		}
	}
	return isolated
}
