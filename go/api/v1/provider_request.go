// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package v1

import (
	"encoding/json"
	"errors"
)

// RequestFacts validates implemented protocol semantics without rewriting source bytes.
func (p ProviderProfile) RequestFacts(source string) (ProviderRequestFacts, error) {
	var zero ProviderRequestFacts
	if err := p.Validate(); err != nil {
		return zero, err
	}
	if uint64(len(source)) > p.MaxBodyBytes {
		return zero, errors.New("profile body limit")
	}
	body, err := Decode[map[string]json.RawMessage]([]byte(source))
	if err != nil || body == nil {
		return zero, errors.New("profile request object")
	}
	for key := range body {
		switch key {
		case "model", "stream", "messages", "max_completion_tokens", "max_tokens", "n", "temperature", "top_p", "frequency_penalty", "presence_penalty", "seed", "stop", "stream_options", "user", "response_format":
		default:
			return zero, errors.New("unregistered provider field")
		}
	}
	model, modelOK := providerValue[string](body["model"])
	stream, streamOK := providerValue[bool](body["stream"])
	if !modelOK || !providerIdentifier(model) || !streamOK || !stream {
		return zero, errors.New("provider response profile")
	}
	if raw, present := body["n"]; present {
		n, ok := providerValue[uint64](raw)
		if !ok || n != 1 {
			return zero, errors.New("single completion choice required")
		}
	}
	modern, hasModern := body["max_completion_tokens"]
	legacy, hasLegacy := body["max_tokens"]
	if hasModern == hasLegacy {
		return zero, errors.New("one token cap required")
	}
	cap := modern
	if hasLegacy {
		cap = legacy
	}
	tokens, ok := providerValue[uint64](cap)
	if !ok || tokens == 0 || tokens > p.MaxOutputTokens {
		return zero, errors.New("profile token limit")
	}
	count, err := p.messages(body["messages"])
	if err != nil {
		return zero, err
	}
	if err := providerSampling(body); err != nil {
		return zero, err
	}
	return ProviderRequestFacts{Model: model, OutputTokenLimit: tokens, MessageCount: count}, nil
}

func providerValue[T any](raw json.RawMessage) (T, bool) {
	var value *T
	if json.Unmarshal(raw, &value) == nil && value != nil {
		return *value, true
	}
	var zero T
	return zero, false
}

func (p ProviderProfile) messages(raw json.RawMessage) (uint64, error) {
	messages, ok := providerValue[[]json.RawMessage](raw)
	if !ok || len(messages) == 0 || uint64(len(messages)) > p.MaxMessages {
		return 0, errors.New("profile message bound")
	}
	for _, message := range messages {
		fields, ok := providerValue[map[string]json.RawMessage](message)
		if !ok {
			return 0, errors.New("message object required")
		}
		for key := range fields {
			if key != "role" && key != "content" && key != "name" {
				return 0, errors.New("unregistered message field")
			}
		}
		role, ok := providerValue[string](fields["role"])
		if !ok || (role != "system" && role != "developer" && role != "user" && role != "assistant") {
			return 0, errors.New("unregistered message role")
		}
		if _, ok := providerValue[string](fields["content"]); !ok {
			return 0, errors.New("text content required")
		}
		if name, present := fields["name"]; present {
			value, ok := providerValue[string](name)
			if !ok || value == "" || len(value) > 64 {
				return 0, errors.New("message name")
			}
		}
	}
	return uint64(len(messages)), nil
}
