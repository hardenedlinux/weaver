// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
)

func TestProviderRustDirectReviewedCatalogImport(t *testing.T) {
	const source = `{"model_list":[{"model_name":"alias","litellm_params":{"model":"openai/model","api_base":"https://provider.example/v1/","api_key":"os.environ/KEY"}}]}`
	const yaml = `model_list:
  - model_name: alias
    litellm_params:
      model: openai/model
      api_base: https://provider.example/v1/
      api_key: os.environ/KEY
`
	profile, err := providerProfile().Digest()
	if err != nil {
		t.Fatal(err)
	}
	plan := v1.ProviderPlan{Family: "original", Node: "run", Profile: "p", ProfileCommitment: profile, Model: "model",
		Body:    `{"model":"model","stream":true,"max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`,
		Ceiling: 4, Routes: []v1.ProviderRoute{{Target: "bound", Endpoint: "https://provider.example/v1/chat/completions"}}}
	review := config.ProviderImportReview{Bindings: map[string]config.ProviderImportBinding{"alias": {
		Plan: plan, Credential: "os.environ/KEY",
		Entry: json.RawMessage(`{"module":"owned","capabilities":["text"],"latency_millis":1,"user_rates":[0,0,0,0],"quote":{"version":"v1","tenant":"tenant","formula_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","procurement_rates":[0,0,0,0],"token_bounds":[0,0,0,16]}}`),
	}}}
	expected, err := config.ImportProviderCatalog([]byte(source), config.ProfileJSON, review)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	write := func(name string, body []byte) string {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, body, 0600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	record, err := json.Marshal(review)
	if err != nil {
		t.Fatal(err)
	}
	manifest := write("review.json", record)
	var original any
	if err := json.Unmarshal(expected, &original); err != nil {
		t.Fatal(err)
	}
	for format, input := range map[string]string{"json": source, "yaml": yaml} {
		result, err := exec.CommandContext(t.Context(), serverBinary, "import-provider", format,
			write("source."+format, []byte(input)), manifest).Output()
		var candidate any
		if err != nil || json.Unmarshal(result, &candidate) != nil || !reflect.DeepEqual(original, candidate) || bytes.Contains(result, []byte("os.environ/KEY")) {
			t.Fatalf("%s reviewed import differs from the original proposal: %v %s", format, err, result)
		}
	}
	for _, invalid := range []struct{ name, input string }{
		{"duplicate", yaml + "      api_key: os.environ/KEY\n"},
		{"tagged", strings.Replace(yaml, "api_key: os.environ/KEY", "api_key: !custom os.environ/KEY", 1)},
		{"second-document", yaml + "---\nmodel_list: []\n"},
	} {
		result, err := exec.CommandContext(t.Context(), serverBinary, "import-provider", "yaml",
			write(invalid.name+".yaml", []byte(invalid.input)), manifest).Output()
		if err == nil || len(result) != 0 {
			t.Fatalf("%s YAML emitted a catalog proposal", invalid.name)
		}
	}
}
