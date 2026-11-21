// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && schemeintegration && !windows

package dev

import (
	"context"
	"testing"

	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/controlplane"
)

// Same complete compiled-source benchmark, sharing the real final-send fixture
// with the Go/Cedar/Rust path. Scheme semantics and preparation are unchanged.
func BenchmarkGatewayCompiledPipeline(b *testing.B) {
	for _, assets := range []bool{false, true} {
		name := "inline"
		if assets {
			name = "assets"
		}
		b.Run(name, func(b *testing.B) {
			prepare := func(b *testing.B, f *fixture, bundle config.Bundle) {
				catalog := configuredCatalogPath(b, f, bundle)
				f.stop(b)
				f.env = append(f.env, "WEAVER_GOVERNANCE_CATALOG="+catalog)
				if assets {
					configureGovernanceAsset(b, f, bundle.Publication.Policy)
				}
				f.start(b)
			}
			activate := func(ctx context.Context, f *fixture, _ config.Bundle) (*controlplane.Gateway, error) {
				return controlplane.BootstrapProducer(ctx, f.admin, f.client, "approved-control")
			}
			benchmarkPublishedExecution(b, prepare, activate)
		})
	}
}
