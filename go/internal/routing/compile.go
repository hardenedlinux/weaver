// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Package routing refines original routine/node constraints into a proposal.
// It has no provider client, credential access, ledger mutation or send permit.
package routing

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	contract "github.com/HardenedLinux/weaver/go/api/v1"
	"math"
	"slices"
)

func Compile(task contract.Task, request contract.Request, view contract.View) (contract.Proposal, error) {
	var zero contract.Proposal
	if task.ProviderProfile != nil {
		return zero, errors.New("provider profile cannot use an untyped request path")
	}
	if !slices.Contains(task.Nodes, request.Node) || !slices.Contains(task.Models, request.Model) || request.Ceiling == 0 || task.Budget == 0 || task.Budget > math.MaxInt64 {
		return zero, errors.New("request outside original task")
	}
	body, err := contract.Decode[map[string]json.RawMessage]([]byte(request.Body))
	if err != nil {
		return zero, err
	}
	var model string
	if err := json.Unmarshal(body["model"], &model); err != nil || model != request.Model {
		return zero, errors.New("wire model mismatch")
	}
	if stream, ok := body["stream"]; ok && string(stream) != "false" {
		return zero, errors.New("streaming profile unavailable")
	}
	if _, ok := body["tools"]; ok {
		return zero, errors.New("tool profile unavailable")
	}
	if _, ok := body["tool_choice"]; ok {
		return zero, errors.New("tool profile unavailable")
	}
	digest := sha256.Sum256([]byte(request.Body))
	if task.BodyDigests[request.Node] != hex.EncodeToString(digest[:]) {
		return zero, errors.New("original body commitment mismatch")
	}
	target := ""
	for _, candidate := range request.Targets {
		if slices.Contains(task.Targets, candidate) && task.Endpoints[candidate] != "" {
			target = candidate
			break
		}
	}
	if target == "" {
		return zero, errors.New("no original eligible target")
	}
	ceiling := min(request.Ceiling, task.Budget)
	if bound := task.NodeCostBounds[request.Node]; bound == 0 || bound > ceiling {
		return zero, errors.New("reservation below original cost bound")
	}
	return contract.Proposal{Family: task.Family, Node: request.Node, Profile: task.Profile, Target: target, Endpoint: task.Endpoints[target], Model: request.Model, Body: request.Body, Ceiling: ceiling, Revision: view.Revision, Fence: view.Fence}, nil
}
