// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"os"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
)

var sourceBaseline = flag.String("source-baseline", "", "Explicit retained baseline executable for the source-owner comparison benchmark only")

// BenchmarkGatewaySourceOwnerComparison uses a balanced ABBAAB order. Invoke with
// -benchtime=256x -count=1; each child performs the same number of unique commits.
// Tests and the default benchmarks always use the freshly built current server.
func BenchmarkGatewaySourceOwnerComparison(b *testing.B) {
	if *sourceBaseline == "" {
		b.Fatal("explicit -source-baseline is required")
	}
	for _, pair := range []struct{ name, binary string }{
		{"A1-reopen", *sourceBaseline}, {"B1-owned", serverBinary}, {"B2-owned", serverBinary},
		{"A2-reopen", *sourceBaseline}, {"A3-reopen", *sourceBaseline}, {"B3-owned", serverBinary},
	} {
		b.Run(pair.name, func(b *testing.B) {
			file, err := os.Open(pair.binary)
			if err != nil {
				b.Fatal(err)
			}
			hash := sha256.New()
			_, readError := io.Copy(hash, file)
			closeError := file.Close()
			if readError != nil || closeError != nil {
				b.Fatalf("binary hash: %v %v", readError, closeError)
			}
			b.Logf("binary=%s sha256=%s", pair.binary, hex.EncodeToString(hash.Sum(nil)))
			f := fixtureWithBinary(b, completeSSE, false, pair.binary)
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			revision := uint64(0)
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: fmt.Sprintf("pair-%d", revision), ExpectedRevision: &revision, Fence: 1, Policy: f.policy, Schema: f.schema})
				if err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED || receipt.GetRevision() != revision+1 {
					b.Fatalf("source CAS: %v %v", receipt, err)
				}
				revision = receipt.GetRevision()
			}
			if f.primary.Load() != 0 || f.backup.Load() != 0 || f.denied.Load() != 0 {
				b.Fatal("source commit invoked a provider")
			}
		})
	}
}
