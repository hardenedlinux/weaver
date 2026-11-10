// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"reflect"
	"slices"
	"strings"
	"testing"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/routing"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestPublishedProviderBindingOwnsExactOriginal(t *testing.T) {
	_, bundle := artifactFixture(t)
	client := &gatewayclient.Client{RPC: &sourceRPC{publication: bundle.Publication}, Token: "source-token"}
	gateway, err := Bootstrap(t.Context(), client, client, bundle)
	if err != nil {
		t.Fatal(err)
	}
	proposal := bundle.Plans[0]
	proposal.Routes = slices.Clone(proposal.Routes)
	expected, err := routing.CompileProvider(bundle.Tasks[0], proposal, bundle.View())
	if err != nil {
		t.Fatal(err)
	}
	bundle.Plans[0].Body = "replaced"
	bundle.Plans[0].Routes[0].Endpoint = "https://replacement.invalid"
	proposal.Revision, proposal.Fence = 999, 999
	got, _, err := gateway.compileProvider(t.Context(), proposal)
	if err != nil || !reflect.DeepEqual(got, expected) {
		t.Fatalf("published binding diverged from the admitted original: %v", err)
	}
	for _, change := range []func(*v1.ProviderPlan){
		func(p *v1.ProviderPlan) { p.Family += "-changed" },
		func(p *v1.ProviderPlan) { p.Node += "-changed" },
		func(p *v1.ProviderPlan) { p.Profile += "-changed" },
		func(p *v1.ProviderPlan) { p.ProfileCommitment += "-changed" },
		func(p *v1.ProviderPlan) { p.Model += "-changed" },
		func(p *v1.ProviderPlan) { p.Ceiling++ },
		func(p *v1.ProviderPlan) { p.Body += " " },
		func(p *v1.ProviderPlan) { p.Routes[0].Endpoint += "/changed" },
	} {
		changed := proposal
		changed.Routes = slices.Clone(proposal.Routes)
		change(&changed)
		if _, _, err := gateway.compileProvider(t.Context(), changed); status.Code(err) != codes.PermissionDenied {
			t.Fatalf("changed original was not rejected: %v", err)
		}
	}
}

func BenchmarkPublishedProviderBinding(b *testing.B) {
	for _, size := range []int{128, 65536} {
		_, bundle := artifactFixture(b)
		task, proposal := bundle.Tasks[0], bundle.Plans[0]
		task.ProviderProfile.MaxBodyBytes = 1 << 20
		proposal.Body = strings.Replace(proposal.Body, "hello", strings.Repeat("x", size), 1)
		var err error
		proposal.ProfileCommitment, err = task.ProviderProfile.Digest()
		if err != nil {
			b.Fatal(err)
		}
		task.StreamContracts[proposal.Node], err = proposal.Digest()
		if err != nil {
			b.Fatal(err)
		}
		body := sha256.Sum256([]byte(proposal.Body))
		task.BodyDigests[proposal.Node] = hex.EncodeToString(body[:])
		view := bundle.View()
		original, err := routing.CompileProvider(task, proposal, view)
		if err != nil {
			b.Fatal(err)
		}
		gateway := &Gateway{operations: map[[2]string]v1.ProviderPlan{{proposal.Family, proposal.Node}: original}}
		proposal.Body = strings.Clone(proposal.Body)
		for _, name := range []string{"repeat-projection", "published-binding"} {
			b.Run(fmt.Sprintf("%d/%s", size, name), func(b *testing.B) {
				b.ReportAllocs()
				for b.Loop() {
					if name == "repeat-projection" {
						_, err = routing.CompileProvider(task, proposal, view)
					} else {
						_, _, err = gateway.compileProvider(context.Background(), proposal)
					}
					if err != nil {
						b.Fatal(err)
					}
				}
			})
		}
	}
}
