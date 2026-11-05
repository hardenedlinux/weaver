// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"testing"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
)

// Projection measures protobuf-to-owned-source admission. Bootstrap measures the
// complete local control path with an inert test RPC recorder, including every
// copy/validation/digest call. Neither is an RPC/storage/FFI benchmark; the real
// chain is measured separately by BenchmarkGatewayCompiledPipeline.
func BenchmarkCompiledSourceAdmission(b *testing.B) {
	for _, bootstrap := range []bool{false, true} {
		name := "projection"
		if bootstrap {
			name = "bootstrap"
		}
		for _, size := range []int{128, 16384, 524288} {
			b.Run(fmt.Sprintf("%s/%d", name, size), func(b *testing.B) {
				input, bundle := artifactFixture(b)
				task, plan := bundle.Tasks[0], bundle.Plans[0]
				task.ProviderProfile.MaxBodyBytes = 1 << 20
				plan.Body = strings.Replace(plan.Body, "hello", strings.Repeat("x", size), 1)
				var err error
				plan.ProfileCommitment, err = task.ProviderProfile.Digest()
				if err != nil {
					b.Fatal(err)
				}
				task.StreamContracts[plan.Node], err = plan.Digest()
				if err != nil {
					b.Fatal(err)
				}
				digest := sha256.Sum256([]byte(plan.Body))
				task.BodyDigests[plan.Node] = hex.EncodeToString(digest[:])
				input.Tasks = []*pb.Task{gatewayclient.Task(task)}
				input.Plans = []*pb.ProviderPlan{gatewayclient.Plan(plan)}
				rpc := &sourceRPC{artifact: input, publication: bundle.Publication, calls: make([]string, 0, 6)}
				client := &gatewayclient.Client{RPC: rpc, Token: "source-token"}
				b.ReportAllocs()
				b.ResetTimer()
				for b.Loop() {
					if bootstrap {
						rpc.calls = rpc.calls[:0]
						result, err := BootstrapProducer(context.Background(), client, client, "approved")
						if err != nil || result.tasks[task.Family].BodyDigests[plan.Node] != task.BodyDigests[plan.Node] || len(rpc.calls) != 6 {
							b.Fatal("local source bootstrap", err)
						}
					} else {
						result, err := compiledBundle(input)
						if err != nil || result.Plans[0].Body != plan.Body {
							b.Fatal("source admission", err)
						}
					}
				}
			})
		}
	}
}
