// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package config

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strings"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

const maxImportBytes = 262144

var credentialReference = regexp.MustCompile(`^os\.environ/[A-Z_][A-Z0-9_]{0,127}$`)

type ProviderImportReview struct {
	Parent   string                           `json:"parent"`
	Bindings map[string]ProviderImportBinding `json:"bindings"`
}

type ProviderImportBinding struct {
	Plan       v1.ProviderPlan `json:"plan"`
	Credential string          `json:"credential_reference"`
	Entry      json.RawMessage `json:"entry"`
}

type externalModel struct {
	Name   string `json:"model_name"`
	Params struct {
		Model      string `json:"model"`
		Base       string `json:"api_base"`
		Credential string `json:"api_key"`
	} `json:"litellm_params"`
}

// ImportProviderCatalog only emits the record consumed by PublishProviderCatalog.
// The operator's review input owns plans, target references and tariff metadata.
func ImportProviderCatalog(data []byte, format ProfileFormat, review ProviderImportReview) ([]byte, error) {
	if len(data) == 0 || len(data) > maxImportBytes {
		return nil, fmt.Errorf("provider import input bound")
	}
	if review.Parent != "" {
		if raw, err := hex.DecodeString(review.Parent); err != nil || len(raw) != 32 || strings.ToLower(review.Parent) != review.Parent {
			return nil, fmt.Errorf("provider import parent digest")
		}
	}
	data, err := sourceJSON(data, format)
	if err != nil {
		return nil, err
	}
	doc, err := v1.Decode[struct {
		Models []externalModel `json:"model_list"`
	}](data)
	if err != nil {
		return nil, fmt.Errorf("unsupported or malformed LiteLLM provider configuration")
	}
	if len(doc.Models) == 0 || len(doc.Models) > 256 || len(doc.Models) != len(review.Bindings) {
		return nil, fmt.Errorf("provider import inventory mismatch")
	}
	entries := make(map[string]json.RawMessage, len(doc.Models))
	seen := make(map[string]bool, len(doc.Models))
	for i, model := range doc.Models {
		binding, ok := review.Bindings[model.Name]
		if !ok || model.Name == "" || seen[model.Name] || !matchesImport(model, binding) {
			return nil, fmt.Errorf("provider import model %d does not match its reviewed binding", i)
		}
		digest, err := binding.Plan.Digest()
		if err != nil {
			return nil, err
		}
		if _, exists := entries[digest]; exists {
			return nil, fmt.Errorf("duplicate imported plan")
		}
		seen[model.Name] = true
		entries[digest] = binding.Entry
	}
	record, err := json.Marshal(struct {
		Parent  string                     `json:"parent"`
		Entries map[string]json.RawMessage `json:"entries"`
	}{review.Parent, entries})
	if err != nil || len(record) > maxImportBytes {
		return nil, fmt.Errorf("invalid or oversized catalog proposal")
	}
	return record, nil
}

func matchesImport(model externalModel, binding ProviderImportBinding) bool {
	p := model.Params
	if len(binding.Plan.Routes) != 1 || binding.Plan.Model == "" ||
		p.Model != "openai/"+binding.Plan.Model ||
		!credentialReference.MatchString(p.Credential) || p.Credential != binding.Credential ||
		len(binding.Entry) == 0 || binding.Entry[0] != '{' {
		return false
	}
	base, err := url.Parse(p.Base)
	return err == nil && base.Scheme == "https" && base.Hostname() != "" && base.User == nil &&
		base.RawQuery == "" && !base.ForceQuery && !strings.Contains(p.Base, "#") &&
		strings.TrimSuffix(p.Base, "/")+"/chat/completions" == binding.Plan.Routes[0].Endpoint
}
