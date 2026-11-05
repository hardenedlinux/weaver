// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Package metering signs original terminal usage outside the gateway.
package metering

import (
	"context"
	"crypto/ed25519"
	"errors"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

type Issuer struct {
	Audience, Tenant, ID string
	Key                  ed25519.PrivateKey
}

// Settle uses a deterministic application identity. A restarted issuer reads
// the same durable observation and signs the same message.
func (i Issuer) Settle(ctx context.Context, client pb.GatewayClient, key *pb.OperationKey) (*pb.MeteringApplication, error) {
	if key == nil || key.Family == "" || key.Node == "" || i.Audience == "" || i.Tenant == "" || i.ID == "" {
		return nil, errors.New("metering identity or operation missing")
	}
	r, err := client.InspectTerminalUsage(ctx, key)
	if err != nil {
		return nil, err
	}
	if r.GetAudience() != i.Audience || r.GetTenant() != i.Tenant || r.GetIssuer() != i.ID ||
		r.GetFamily() != key.Family || r.GetNode() != key.Node || len(r.GetTokens()) != 4 ||
		len(r.GetTerminalDigest()) != 64 || r.GetApplication() != r.GetTerminalDigest() || r.GetSignature() != "" {
		return nil, errors.New("unexpected terminal usage binding")
	}
	usage := v1.TerminalUsage{
		Audience: r.Audience, Tenant: r.Tenant, Issuer: r.Issuer, Application: r.Application,
		Family: r.Family, Node: r.Node, Origin: r.Origin, PlanDigest: r.PlanDigest,
		Target: r.Target, FormulaDigest: r.FormulaDigest, TerminalDigest: r.TerminalDigest, Tokens: [4]uint64(r.Tokens),
	}
	r.Signature, err = usage.Sign(i.Key)
	if err != nil {
		return nil, err
	}
	return client.ApplyMetering(ctx, r)
}
