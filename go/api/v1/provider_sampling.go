// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package v1

import (
	"encoding/json"
	"errors"
)

func providerSampling(body map[string]json.RawMessage) error {
	for _, bound := range []struct {
		key       string
		low, high float64
	}{
		{"temperature", 0, 2}, {"top_p", 0, 1}, {"frequency_penalty", -2, 2}, {"presence_penalty", -2, 2},
	} {
		if raw, present := body[bound.key]; present {
			value, ok := providerValue[float64](raw)
			if !ok || value < bound.low || value > bound.high {
				return errors.New("sampling parameter")
			}
		}
	}
	if raw, present := body["seed"]; present {
		if _, ok := providerValue[int64](raw); !ok {
			return errors.New("provider seed")
		}
	}
	if raw, present := body["user"]; present && !providerText(raw) {
		return errors.New("provider user tag")
	}
	if raw, present := body["stop"]; present && !providerText(raw) {
		items, ok := providerValue[[]json.RawMessage](raw)
		if !ok || len(items) == 0 || len(items) > 4 {
			return errors.New("stop sequence bound")
		}
		for _, item := range items {
			if !providerText(item) {
				return errors.New("stop sequence")
			}
		}
	}
	if raw, present := body["stream_options"]; present {
		fields, ok := providerValue[map[string]json.RawMessage](raw)
		if !ok {
			return errors.New("stream options object")
		}
		for key, value := range fields {
			if _, ok := providerValue[bool](value); key != "include_usage" || !ok {
				return errors.New("stream option")
			}
		}
	}
	if raw, present := body["response_format"]; present {
		fields, ok := providerValue[map[string]json.RawMessage](raw)
		if !ok || len(fields) != 1 {
			return errors.New("text response format required")
		}
		kind, ok := providerValue[string](fields["type"])
		if !ok || kind != "text" {
			return errors.New("text response format required")
		}
	}
	return nil
}

func providerText(raw json.RawMessage) bool {
	value, ok := providerValue[string](raw)
	return ok && value != "" && len(value) <= 256
}
