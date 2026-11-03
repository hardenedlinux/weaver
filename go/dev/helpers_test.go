// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

// Package dev contains development-only assurance tests, outside the production command graph.
package dev

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func root(t testing.TB) string {
	t.Helper()
	_, path, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate development tests")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(path), "../.."))
}
func writeJSON(t testing.TB, path string, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
}
func readJSON[T any](t testing.TB, path string) T {
	t.Helper()
	var value T
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(data, &value); err != nil {
		t.Fatal(err)
	}
	return value
}
