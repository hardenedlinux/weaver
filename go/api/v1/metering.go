// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package v1

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
)

// NormalizeProviderTokens returns uncached input, cache read, cache write and
// output. A provider adapter supplies the inclusive/exclusive convention.
func NormalizeProviderTokens(input, read, write, output uint64, inclusive bool) ([4]uint64, error) {
	if inclusive {
		if read > input || write > input-read {
			return [4]uint64{}, errors.New("provider cache counters exceed total input")
		}
		input -= read + write
	}
	tokens := [4]uint64{input, read, write, output}
	for _, value := range tokens {
		if value > math.MaxInt64 {
			return [4]uint64{}, errors.New("provider counter exceeds metering range")
		}
	}
	return tokens, nil
}

func MeteringFormulaDigest(rates [4]uint64) (string, error) {
	body, err := json.Marshal([]any{"weaver.metering.linear-ceil-per-million.v1", rates})
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:]), nil
}

// TerminalUsage is supplied by the independent issuer after it has qualified
// the terminal observation. The signing helper does not establish that fact.
type TerminalUsage struct {
	Audience, Tenant, Issuer, Application, Family, Node, Origin string
	PlanDigest, Target, FormulaDigest, TerminalDigest           string
	Tokens                                                      [4]uint64
}

func (u TerminalUsage) Sign(key ed25519.PrivateKey) (string, error) {
	if len(key) != ed25519.PrivateKeySize {
		return "", errors.New("invalid metering private key")
	}
	body, err := json.Marshal([]any{
		"weaver.provider-terminal-usage.v1", u.Audience, u.Tenant, u.Issuer,
		u.Application, u.Family, u.Node, u.Origin, u.PlanDigest, u.Target,
		u.FormulaDigest, u.TerminalDigest, u.Tokens,
	})
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(body)
	return hex.EncodeToString(ed25519.Sign(key, sum[:])), nil
}
