// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"testing"
	"testing/quick"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

func TestProviderImportRetainsReviewedPlan(t *testing.T) {
	err := quick.Check(func(n uint8, trailingSlash bool) bool {
		base := fmt.Sprintf("https://p%d.example/v1", n)
		plan := v1.ProviderPlan{Family: "original", Node: "run", Model: "model", Routes: []v1.ProviderRoute{{Target: "bound", Endpoint: base + "/chat/completions"}}}
		if trailingSlash {
			base += "/"
		}
		review := ProviderImportReview{Bindings: map[string]ProviderImportBinding{
			"alias": {Plan: plan, Credential: "os.environ/KEY", Entry: json.RawMessage(`{"module":"owned"}`)},
		}}
		yaml := fmt.Sprintf("model_list:\n  - model_name: alias\n    litellm_params:\n      model: openai/model\n      api_base: %s\n      api_key: os.environ/KEY\n", base)
		source := fmt.Sprintf(`{"model_list":[{"model_name":"alias","litellm_params":{"model":"openai/model","api_base":%q,"api_key":"os.environ/KEY"}}]}`, base)
		y, err := ImportProviderCatalog([]byte(yaml), ProfileYAML, review)
		j, jerr := ImportProviderCatalog([]byte(source), ProfileJSON, review)
		digest, _ := plan.Digest()
		_, bad := ImportProviderCatalog([]byte(yaml+"      num_retries: 2\n"), ProfileYAML, review)
		_, replaced := ImportProviderCatalog(bytes.ReplaceAll([]byte(source), []byte("openai/model"), []byte("openai/other")), ProfileJSON, review)
		_, duplicate := ImportProviderCatalog([]byte(yaml+"      api_key: os.environ/KEY\n"), ProfileYAML, review)
		return err == nil && jerr == nil && bytes.Equal(y, j) && bytes.Contains(j, []byte(digest)) && !bytes.Contains(j, []byte("KEY")) &&
			bad != nil && replaced != nil && duplicate != nil
	}, &quick.Config{MaxCount: 128})
	if err != nil {
		t.Fatal(err)
	}
}
