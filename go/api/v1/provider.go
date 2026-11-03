// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package v1

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
)

type ProviderRoute struct {
	Target   string `json:"target"`
	Endpoint string `json:"endpoint"`
}
type ProviderPlan struct {
	Family            string          `json:"family"`
	Node              string          `json:"node"`
	Profile           string          `json:"profile"`
	ProfileCommitment string          `json:"profile_commitment"`
	Model             string          `json:"model"`
	Body              string          `json:"body"`
	Routes            []ProviderRoute `json:"routes"`
	Ceiling           uint64          `json:"ceiling"`
	Revision          uint64          `json:"revision"`
	Fence             uint64          `json:"fence"`
}

func (p ProviderPlan) Digest() (string, error) {
	body := sha256.Sum256([]byte(p.Body))
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if err := e.Encode([]any{"weaver.provider-plan.v2", p.Family, p.Node, p.Profile, p.ProfileCommitment, p.Model, hex.EncodeToString(body[:]), p.Routes, p.Ceiling}); err != nil {
		return "", err
	}
	sum := sha256.Sum256(bytes.TrimSuffix(b.Bytes(), []byte{'\n'}))
	return hex.EncodeToString(sum[:]), nil
}
