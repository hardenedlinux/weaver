// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"testing/quick"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/routing"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestCatalogSelectionUsesOnlyCurrentEntries(t *testing.T) {
	err := quick.Check(func(mask, firstLatency, secondLatency uint8) bool {
		source := routing.Selection{Candidates: []routing.Candidate{
			{Module: "source-a", Plan: v1.ProviderPlan{Model: "a"}},
			{Module: "source-b", Plan: v1.ProviderPlan{Model: "b"}},
		}}
		entries := map[string]catalogEntry{}
		latencies := []uint8{firstLatency, secondLatency}
		var want []routing.Candidate
		for i, candidate := range source.Candidates {
			if mask&(1<<i) == 0 {
				continue
			}
			digest, err := candidate.Plan.Digest()
			if err != nil {
				return false
			}
			entry := catalogEntry{Module: "authoritative", Latency: 1 + uint64(latencies[i])}
			entries[digest] = entry
			candidate.Module, candidate.LatencyMillis = entry.Module, entry.Latency
			want = append(want, candidate)
		}
		selected, err := catalogSelection(source, entries)
		if err != nil || len(selected.Candidates) != len(want) {
			return false
		}
		for i, candidate := range selected.Candidates {
			if candidate.Module != want[i].Module || candidate.Plan.Model != want[i].Plan.Model ||
				candidate.LatencyMillis != want[i].LatencyMillis {
				return false
			}
		}
		return source.Candidates[0].Module == "source-a" && source.Candidates[1].Module == "source-b"
	}, &quick.Config{MaxCount: 128})
	if err != nil {
		t.Fatal(err)
	}
}

func catalogProjectionFixture(t testing.TB) (config.Bundle, []byte, v1.ProviderPlan) {
	t.Helper()
	_, bundle := artifactFixture(t)
	plan := bundle.Plans[0]
	entry := catalogEntry{Module: "catalog", Latency: 1}
	entry.Quote.TokenBounds[3] = 8
	digest, err := plan.Digest()
	if err != nil {
		t.Fatal(err)
	}
	record, err := json.Marshal(map[string]any{"entries": map[string]catalogEntry{digest: entry}})
	if err != nil {
		t.Fatal(err)
	}
	bundle.Plans = nil
	bundle.SelectOnRequest = true
	bundle.Tasks[0].BodyDigests, bundle.Tasks[0].StreamContracts = nil, nil
	bundle.Routing = []routing.Selection{{
		Node: plan.Node, AllowedModules: []string{entry.Module}, MaxLatencyMillis: 100,
		Candidates: []routing.Candidate{{Module: entry.Module, LatencyMillis: entry.Latency, TokenBounds: entry.Quote.TokenBounds, Plan: plan}},
	}}
	frozen, err := config.FreezeBundle(bundle)
	if err != nil {
		t.Fatal(err)
	}
	return frozen, record, v1.ProviderPlan{Family: plan.Family, Node: plan.Node}
}

type catalogRPC struct {
	sourceRPC
	snapshot *pb.ProviderCatalogSnapshot
	readErr  error
}

func (r *catalogRPC) InspectProviderCatalog(context.Context, *pb.Empty, ...grpc.CallOption) (*pb.ProviderCatalogSnapshot, error) {
	r.calls = append(r.calls, "catalog")
	return r.snapshot, r.readErr
}

func TestCatalogProjectionRequiresExactSnapshotAndLiveAuthority(t *testing.T) {
	bundle, record, key := catalogProjectionFixture(t)
	rpc := &catalogRPC{snapshot: &pb.ProviderCatalogSnapshot{Version: "a", Record: bytes.Clone(record)}}
	gateway := &Gateway{deferred: &bundle, source: &gatewayclient.Client{RPC: rpc}}
	check := func(version string, code codes.Code, wantCalls string) {
		t.Helper()
		rpc.calls = nil
		_, got, err := gateway.compileProvider(t.Context(), key)
		if got != version || status.Code(err) != code || strings.Join(rpc.calls, ",") != wantCalls {
			t.Fatalf("catalog version=%q status=%v calls=%v", got, err, rpc.calls)
		}
	}
	check("a", codes.OK, "catalog,register")
	a := gateway.catalog.Load()
	check("a", codes.OK, "catalog,register")
	if gateway.catalog.Load() != a {
		t.Fatal("identical catalog was projected again")
	}
	rpc.failRegister = true
	check("", codes.Unknown, "catalog,register")
	rpc.failRegister = false
	rpc.readErr = status.Error(codes.PermissionDenied, "catalog authority denied")
	check("", codes.FailedPrecondition, "catalog")
	rpc.readErr = nil
	// The snapshot buffer can be reused by its caller. An invalid replacement
	// with the same version must miss the cache and fail closed.
	rpc.snapshot.Record[0] = '['
	check("", codes.FailedPrecondition, "catalog")
	rpc.snapshot = &pb.ProviderCatalogSnapshot{Version: "b", Record: record}
	check("b", codes.OK, "catalog,register")
	if gateway.catalog.Load() == a || gateway.catalog.Load().version != "b" {
		t.Fatal("a different version reused the original projection")
	}
	rpc.snapshot = &pb.ProviderCatalogSnapshot{Version: "withdrawn", Record: []byte(`{"entries":{}}`)}
	check("", codes.FailedPrecondition, "catalog")
}

func projectCatalogWave(t testing.TB, gateway *Gateway, snapshots [4]*pb.ProviderCatalogSnapshot) [4]config.Bundle {
	t.Helper()
	var bundles [4]config.Bundle
	var errs [4]error
	var workers sync.WaitGroup
	start := make(chan struct{})
	for i, snapshot := range snapshots {
		workers.Go(func() {
			<-start
			projection, err := gateway.projectCatalog(snapshot)
			errs[i] = err
			if err == nil {
				bundles[i] = projection.bundle
			}
		})
	}
	close(start)
	workers.Wait()
	for _, err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	return bundles
}

func TestConcurrentCatalogProjectionSharesExactSnapshot(t *testing.T) {
	bundle, record, _ := catalogProjectionFixture(t)
	gateway := &Gateway{deferred: &bundle}
	for _, version := range []string{"a", "b"} {
		var snapshots [4]*pb.ProviderCatalogSnapshot
		for i := range snapshots {
			snapshots[i] = &pb.ProviderCatalogSnapshot{Version: version, Record: bytes.Clone(record)}
		}
		bundles := projectCatalogWave(t, gateway, snapshots)
		current := gateway.catalog.Load()
		if current.version != version {
			t.Fatal("catalog version was not replaced")
		}
		for _, projected := range bundles {
			if &projected.Plans[0] != &current.bundle.Plans[0] {
				t.Fatal("concurrent request did not reuse the retained projection")
			}
		}
	}
}

func BenchmarkProviderCatalogProjection(b *testing.B) {
	bundle, record, _ := catalogProjectionFixture(b)
	for _, size := range []struct {
		name    string
		padding int
	}{{"one-entry", 0}, {"padded-64KiB", 65536}} {
		snapshot := &pb.ProviderCatalogSnapshot{Version: "a", Record: append(bytes.Clone(record), bytes.Repeat([]byte(" "), size.padding)...)}
		gateway := &Gateway{deferred: &bundle}
		if _, err := gateway.projectCatalog(snapshot); err != nil {
			b.Fatal(err)
		}
		b.Run(size.name+"/repeat-projection", func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				if _, err := projectCatalog(bundle, snapshot.Record); err != nil {
					b.Fatal(err)
				}
			}
		})
		b.Run(size.name+"/exact-snapshot", func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				if _, err := gateway.projectCatalog(snapshot); err != nil {
					b.Fatal(err)
				}
			}
		})
		b.Run(size.name+"/four-misses", func(b *testing.B) {
			var snapshots [4]*pb.ProviderCatalogSnapshot
			for i := range snapshots {
				snapshots[i] = &pb.ProviderCatalogSnapshot{Version: snapshot.Version, Record: bytes.Clone(snapshot.Record)}
			}
			b.ReportAllocs()
			for b.Loop() {
				projectCatalogWave(b, &Gateway{deferred: &bundle}, snapshots)
			}
		})
	}
}
