//go:build integration && !windows

package dev

import (
	"os"
	"path/filepath"
	"testing"
)

// Exercise the actual Go source handoff and Rust final stream guards using the
// official Cedar PolicySet JSON. A true replay result is never an execution API.
func TestProviderControlNamedPolicyJSONRevocationAndRestart(t *testing.T) {
	read := func(name string) string {
		t.Helper()
		data, err := os.ReadFile(filepath.Join("..", "..", "prod", "policies", "review", name))
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}
	policies := controlPolicySources{initial: read("named-permit.json"), revoked: read("named-forbid.json")}
	for _, format := range []string{"json", "yaml"} {
		t.Run(format, func(t *testing.T) { exerciseControlPolicies(t, format, nil, policies) })
	}
}
