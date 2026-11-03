// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

// Package streaming refines a source-owned message manifest into proposal data.
package streaming

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	contract "github.com/HardenedLinux/weaver/go/api/v1"
	"math"
	"slices"
	"unicode/utf8"
)

type MessageRule struct {
	ID        string `json:"id"`
	MaxBytes  uint64 `json:"max_bytes"`
	CostBound uint64 `json:"cost_bound"`
}
type Contract struct {
	Family      string        `json:"family"`
	Node        string        `json:"node"`
	Profile     string        `json:"profile"`
	Target      string        `json:"target"`
	InputDigest string        `json:"input_digest"`
	Destination string        `json:"destination"`
	Messages    []MessageRule `json:"messages"`
}
type Message struct {
	Family         string `json:"family"`
	Node           string `json:"node"`
	Message        string `json:"message"`
	ContractDigest string `json:"contract_digest"`
	Payload        string `json:"payload"`
	Ceiling        uint64 `json:"ceiling"`
	Revision       uint64 `json:"revision"`
	Fence          uint64 `json:"fence"`
}

// Digest uses the same ordered tuple and field projection as the native contract.
func (c Contract) Digest() (string, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode([]any{"weaver.stream.v1", c}); err != nil {
		return "", err
	}
	sum := sha256.Sum256(bytes.TrimSuffix(buffer.Bytes(), []byte{'\n'}))
	return hex.EncodeToString(sum[:]), nil
}

// Compile emits no authority: Rust rechecks the original registry, cost, Policy and fence.
func Compile(task contract.Task, c Contract, id, payload string, ceiling uint64, view contract.View) (Message, error) {
	if task.ProviderProfile != nil {
		return Message{}, errors.New("provider profile cannot use an untyped stream path")
	}
	var zero Message
	digest, err := c.Digest()
	if err != nil || task.StreamContracts[c.Node] != digest {
		return zero, errors.New("original stream manifest commitment mismatch")
	}
	if task.Family != c.Family || task.Profile != c.Profile || !slices.Contains(task.Nodes, c.Node) || !slices.Contains(task.Targets, c.Target) || task.BodyDigests[c.Node] != c.InputDigest {
		return zero, errors.New("stream differs from original source")
	}
	if len(c.Messages) == 0 || len(c.Messages) > 64 || view.Revision > math.MaxInt64 || view.Fence > math.MaxInt64 {
		return zero, errors.New("stream bounds")
	}
	var selected *MessageRule
	var total uint64
	seen := map[string]bool{}
	for index := range c.Messages {
		rule := &c.Messages[index]
		if seen[rule.ID] || rule.MaxBytes == 0 || rule.MaxBytes > 1024*1024 || rule.CostBound == 0 || rule.CostBound > math.MaxInt64-total {
			return zero, errors.New("invalid original message rule")
		}
		seen[rule.ID] = true
		total += rule.CostBound
		if rule.ID == id {
			selected = rule
		}
	}
	if total > task.NodeCostBounds[c.Node] || selected == nil || len(payload) == 0 || !utf8.ValidString(payload) || uint64(len(payload)) > selected.MaxBytes {
		return zero, errors.New("unregistered or oversized message")
	}
	ceiling = min(ceiling, task.Budget)
	if ceiling < selected.CostBound {
		return zero, errors.New("message underreserved")
	}
	return Message{Family: c.Family, Node: c.Node, Message: id, ContractDigest: digest, Payload: payload, Ceiling: ceiling, Revision: view.Revision, Fence: view.Fence}, nil
}
