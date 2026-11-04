// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package routing

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"math"
	"math/big"
	"slices"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

// Selection is deployment-owned routing input for one original operation.
// A model module supplies concrete plans and conservative token bounds.
type Selection struct {
	Node               string      `json:"node"`
	AllowedModules     []string    `json:"allowed_modules"`
	Required           []string    `json:"required"`
	MaxLatencyMillis   uint64      `json:"max_latency_ms"`
	MaxProcurementCost uint64      `json:"max_procurement_cost"`
	UserTokenRates     [4]uint64   `json:"user_token_rates"`
	Candidates         []Candidate `json:"candidates"`
}

type Candidate struct {
	Module           string          `json:"module"`
	Capabilities     []string        `json:"capabilities"`
	LatencyMillis    uint64          `json:"latency_ms"`
	ProcurementRates [4]uint64       `json:"procurement_rates"`
	TokenBounds      [4]uint64       `json:"token_bounds"`
	Plan             v1.ProviderPlan `json:"plan"`
}

// tokenCharge computes the same integer rounding as the Rust metering formula.
// This runs during source activation, outside the request hot path.
func tokenCharge(rates, tokens [4]uint64) (uint64, bool) {
	var total, rate, count big.Int
	for i, price := range rates {
		if price > math.MaxInt64 || tokens[i] > math.MaxInt64 {
			return 0, false
		}
		total.Add(&total, rate.Mul(rate.SetUint64(price), count.SetUint64(tokens[i])))
	}
	total.Add(&total, rate.SetUint64(999_999))
	total.Quo(&total, rate.SetUint64(1_000_000))
	return total.Uint64(), total.IsInt64()
}

// Select filters tenant-authorized modules before ranking estimated procurement
// cost, latency and a stable concrete-plan digest. It never sends or reserves.
func Select(task v1.Task, selection Selection) (v1.ProviderPlan, error) {
	var chosen v1.ProviderPlan
	if task.ProviderProfile == nil || selection.Node == "" || selection.MaxLatencyMillis == 0 ||
		len(selection.Candidates) == 0 || len(selection.Candidates) > 8 {
		return chosen, errors.New("routing selection bounds")
	}
	var cost, latency uint64
	var digest string
	for _, candidate := range selection.Candidates {
		if !slices.Contains(selection.AllowedModules, candidate.Module) ||
			candidate.LatencyMillis == 0 || candidate.LatencyMillis > selection.MaxLatencyMillis {
			continue
		}
		if !slices.ContainsFunc(selection.Required, func(capability string) bool {
			return !slices.Contains(candidate.Capabilities, capability)
		}) {
			plan := candidate.Plan
			facts, err := task.ProviderProfile.RequestFacts(plan.Body)
			if err != nil || plan.Family != task.Family || plan.Node != selection.Node ||
				candidate.TokenBounds[3] < facts.OutputTokenLimit {
				continue
			}
			price, known := tokenCharge(candidate.ProcurementRates, candidate.TokenBounds)
			charge, priced := tokenCharge(selection.UserTokenRates, candidate.TokenBounds)
			if !known || !priced || price > selection.MaxProcurementCost || charge > plan.Ceiling {
				continue
			}
			key, err := plan.Digest()
			if err != nil {
				return chosen, err
			}
			body := sha256.Sum256([]byte(plan.Body))
			candidateTask := task
			candidateTask.BodyDigests = map[string]string{plan.Node: hex.EncodeToString(body[:])}
			candidateTask.StreamContracts = map[string]string{plan.Node: key}
			if _, err := CompileProvider(candidateTask, plan, v1.View{}); err != nil {
				continue
			}
			if digest == "" || price < cost || price == cost &&
				(candidate.LatencyMillis < latency || candidate.LatencyMillis == latency && key < digest) {
				chosen, digest, cost, latency = plan, key, price, candidate.LatencyMillis
			}
		}
	}
	if digest == "" {
		return chosen, errors.New("no eligible model candidate")
	}
	return chosen, nil
}
