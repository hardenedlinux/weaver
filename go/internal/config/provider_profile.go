// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Package config admits typed configuration data without evaluating Scheme or granting authority.
package config

import (
	"encoding/json"
	"errors"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

type ProfileFormat string

const (
	ProfileJSON ProfileFormat = "json"
	ProfileYAML ProfileFormat = "yaml"
)

// DecodeProviderProfile returns canonical source data, never an execution grant.
func DecodeProviderProfile(source []byte, format ProfileFormat) (v1.ProviderProfile, error) {
	var zero v1.ProviderProfile
	if len(source) > 16384 {
		return zero, errors.New("profile configuration bound")
	}
	var fields map[string]json.RawMessage
	var err error
	switch format {
	case ProfileJSON:
		fields, err = v1.Decode[map[string]json.RawMessage](source)
	case ProfileYAML:
		fields, err = profileYAML(source)
	default:
		return zero, errors.New("unsupported profile configuration format")
	}
	if err != nil {
		return zero, err
	}
	if len(fields) != 5 {
		return zero, errors.New("complete profile fields required")
	}
	for key := range fields {
		switch key {
		case "id", "protocol", "max_output_tokens", "max_messages", "max_body_bytes":
		default:
			return zero, errors.New("unknown profile field")
		}
	}
	encoded, err := json.Marshal(fields)
	if err != nil {
		return zero, err
	}
	profile, err := v1.Decode[v1.ProviderProfile](encoded)
	if err != nil {
		return zero, err
	}
	if err := profile.Validate(); err != nil {
		return zero, err
	}
	return profile, nil
}
