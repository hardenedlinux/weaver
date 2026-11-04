// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package fuzzcontrol

import (
	"context"
	"testing"
	"time"
)

func FuzzNoop(f *testing.F) {
	f.Add([]byte("original"))
	f.Fuzz(func(t *testing.T, input []byte) {
		time.Sleep(time.Millisecond)
	})
}

func FuzzPropertyFailure(f *testing.F) {
	f.Add([]byte("original"))
	f.Fuzz(func(t *testing.T, input []byte) {
		t.Fatalf("WeaverNegativeControl: actual property failure: %v", context.DeadlineExceeded)
	})
}
