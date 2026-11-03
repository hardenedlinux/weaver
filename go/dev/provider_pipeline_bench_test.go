//go:build integration && schemeintegration && !windows

package dev

import (
	"context"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/controlplane"
	"os"
	"path/filepath"
	"testing"
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
					dir := filepath.Join(f.directory, "assets")
					if err := os.Mkdir(dir, 0700); err != nil {
						b.Fatal(err)
					}
					if err := os.WriteFile(filepath.Join(dir, "policy.cedar"), []byte(bundle.Publication.Policy), 0600); err != nil {
						b.Fatal(err)
					}
					f.env = append(f.env, "WEAVER_TEST_GOVERNANCE_ASSET_ROOT="+dir)
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
