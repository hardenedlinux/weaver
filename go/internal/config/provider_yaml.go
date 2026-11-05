// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"gopkg.in/yaml.v3"
	"io"
	"strconv"
)

func profileYAML(source []byte) (map[string]json.RawMessage, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(source))
	var document, trailing yaml.Node
	if err := decoder.Decode(&document); err != nil {
		return nil, err
	}
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, errors.New("one profile document required")
	}
	if len(document.Content) != 1 {
		return nil, errors.New("profile document required")
	}
	root := document.Content[0]
	if root.Kind != yaml.MappingNode || root.Anchor != "" || root.Tag != "!!map" {
		return nil, errors.New("plain profile mapping required")
	}
	fields := map[string]json.RawMessage{}
	for i := 0; i < len(root.Content); i += 2 {
		key, value := root.Content[i], root.Content[i+1]
		if key.Kind != yaml.ScalarNode || key.Tag != "!!str" || key.Anchor != "" || value.Kind != yaml.ScalarNode || value.Anchor != "" {
			return nil, errors.New("scalar profile fields required; aliases and anchors forbidden")
		}
		if _, duplicate := fields[key.Value]; duplicate {
			return nil, errors.New("duplicate profile field")
		}
		var typed any
		switch key.Value {
		case "id", "protocol":
			if value.Tag != "!!str" {
				return nil, errors.New("profile string required")
			}
			typed = value.Value
		case "max_output_tokens", "max_messages", "max_body_bytes":
			number, err := strconv.ParseUint(value.Value, 10, 64)
			if err != nil || value.Tag != "!!int" || strconv.FormatUint(number, 10) != value.Value {
				return nil, errors.New("canonical decimal profile limit required")
			}
			typed = number
		default:
			return nil, errors.New("unregistered profile configuration field")
		}
		encoded, err := json.Marshal(typed)
		if err != nil {
			return nil, err
		}
		fields[key.Value] = encoded
	}
	return fields, nil
}
