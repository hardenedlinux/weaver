// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package v1

import "testing"

func TestRejectAmbiguousJSON(t *testing.T) {
	for _, source := range []string{`{"node":"a","node":"b"}`, `{"scope":"forged"}`, `{} {}`, `{"ceiling":-1}`, `{"ceiling":1.5}`} {
		if _, err := Decode[Request]([]byte(source)); err == nil {
			t.Fatalf("accepted %s", source)
		}
	}
}

func FuzzDecoderNeverPanics(f *testing.F) {
	f.Add(`{"node":"infer","ceiling":5}`)
	f.Add(`{"node":"x","node":"y"}`)
	f.Fuzz(func(t *testing.T, source string) { _, _ = Decode[Request]([]byte(source)) })
}
