// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package config

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func profileSource(t testing.TB, extension string) []byte {
	t.Helper()
	data, err := os.ReadFile("../../../prod/policies/provider/profile." + extension)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestProviderProfileJSONAndYAMLHaveOneCanonicalCommitment(t *testing.T) {
	left, err := DecodeProviderProfile(profileSource(t, "json"), ProfileJSON)
	if err != nil {
		t.Fatal(err)
	}
	right, err := DecodeProviderProfile(profileSource(t, "yaml"), ProfileYAML)
	if err != nil {
		t.Fatal(err)
	}
	a, err := left.Digest()
	if err != nil {
		t.Fatal(err)
	}
	b, err := right.Digest()
	if err != nil || a != b || left != right {
		t.Fatal("source format changed profile semantics", err)
	}
}

func TestProviderProfileRejectsAmbiguousConfiguration(t *testing.T) {
	base := string(profileSource(t, "yaml"))
	for _, source := range []string{
		base + "id: another\n", base + "---\n" + base,
		strings.Replace(base, "id: p", "id: &name p", 1),
		strings.Replace(base, "id: p", "id: !unknown p", 1),
		strings.Replace(base, "id: p", "id: *missing", 1),
		strings.Replace(base, "4096", "0x1000", 1),
		strings.Replace(base, "4096", "04096", 1),
		strings.Replace(base, "4096", "4096.0", 1),
		strings.Replace(base, "4096", `"4096"`, 1),
		strings.Replace(base, "4096", "4097", 1),
		base + "scope: forged\n", strings.Repeat(" ", 16385),
	} {
		if _, err := DecodeProviderProfile([]byte(source), ProfileYAML); err == nil {
			t.Fatalf("ambiguous YAML admitted: %s", source)
		}
	}
	source := string(profileSource(t, "json"))
	for _, invalid := range []string{
		strings.Replace(source, `"id": "p"`, `"id":"p","id":"other"`, 1),
		strings.Replace(source, `"id"`, `"ID"`, 1),
		strings.Replace(source, `"protocol"`, `"scope"`, 1),
		source + source,
	} {
		if _, err := DecodeProviderProfile([]byte(invalid), ProfileJSON); err == nil {
			t.Fatal("ambiguous JSON admitted")
		}
	}
}

func FuzzProviderProfileConfiguration(f *testing.F) {
	f.Add(string(profileSource(f, "json")), false)
	f.Add(string(profileSource(f, "yaml")), true)
	f.Fuzz(func(t *testing.T, source string, yaml bool) {
		format := ProfileJSON
		if yaml {
			format = ProfileYAML
		}
		profile, err := DecodeProviderProfile([]byte(source), format)
		if err != nil {
			return
		}
		if err := profile.Validate(); err != nil {
			t.Fatal("invalid configured profile", err)
		}
		digest, err := profile.Digest()
		if err != nil {
			t.Fatal(err)
		}
		encoded, err := json.Marshal(profile)
		if err != nil {
			t.Fatal(err)
		}
		canonical, err := DecodeProviderProfile(encoded, ProfileJSON)
		if err != nil {
			t.Fatal(err)
		}
		second, err := canonical.Digest()
		if err != nil || digest != second {
			t.Fatal("configuration reinterpreted profile", err)
		}
	})
}
