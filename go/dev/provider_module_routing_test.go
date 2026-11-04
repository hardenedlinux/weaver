// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/routing"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestProviderModuleSelectionBindsOriginal(t *testing.T) {
	f := fixtureWithInvocation(t, completeSSE, false, serverBinary, nil, nil, func(plan v1.ProviderPlan) string {
		digest, err := plan.Digest()
		if err != nil {
			t.Fatal(err)
		}
		formula := sha256.Sum256([]byte(`["weaver.metering.linear-ceil-per-million.v1",[0,0,0,100000]]`))
		plan.Family = "control"
		controlDigest, err := plan.Digest()
		if err != nil {
			t.Fatal(err)
		}
		quote := map[string]any{"version": "v1", "tenant": "tenant", "formula_digest": hex.EncodeToString(formula[:]), "procurement_rates": [4]uint64{1000000}, "token_bounds": [4]uint64{64, 0, 0, 32}}
		data, err := json.Marshal(map[string]any{
			"audience":        "routing-meter",
			"tenants":         map[string]any{"tenant": map[string]any{"issuer": "meter", "public_key": strings.Repeat("1", 64), "principals": []string{"alice"}, "rates": [4]uint64{0, 0, 0, 100000}}},
			"quotas":          map[string]any{"families": map[string]string{"f": "key", "control": "key"}, "keys": map[string]any{"key": map[string]any{"principal": "alice", "limit": 4}}, "users": map[string]uint64{"alice": 4}, "tenants": map[string]uint64{"tenant": 4}},
			"provider_quotes": map[string]any{digest: quote, controlDigest: quote},
		})
		if err != nil {
			t.Fatal(err)
		}
		return "WEAVER_METERING=" + string(data)
	})
	bundle := controlBundle(t, f)
	selected := append([]string(nil), bundle.Governance.OpenNodes[:1]...)
	bundle.Governance.OpenNodes = selected
	task := &bundle.Tasks[0]
	task.Nodes, task.Models = selected, []string{"model-a", "model-b"}
	task.BodyDigests, task.StreamContracts = nil, nil
	delete(task.NodeCostBounds, "next")
	qualified := bundle.Plans[0]
	cheap := qualified
	cheap.Model = "model-b"
	cheap.Body = strings.Replace(cheap.Body, "model-a", "model-b", 1)
	bundle.Plans = nil
	bundle.SelectOnRequest = true
	bundle.Routing = []routing.Selection{{
		Node: qualified.Node, AllowedModules: []string{"basic", "premium"}, Required: []string{"quality"},
		MaxLatencyMillis: 100, MaxProcurementCost: 100, UserTokenRates: [4]uint64{0, 0, 0, 100000},
		Candidates: []routing.Candidate{
			{Module: "basic", LatencyMillis: 10, TokenBounds: [4]uint64{64, 0, 0, 32}, Plan: cheap},
			{Module: "premium", Capabilities: []string{"quality"}, LatencyMillis: 40, ProcurementRates: [4]uint64{1_000_000}, TokenBounds: [4]uint64{64, 0, 0, 32}, Plan: qualified},
		},
	}}
	control := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	control.start(t)
	t.Cleanup(func() { control.stop(t) })
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	if _, err := control.client.Execute(ctx, cheap, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); status.Code(err) != codes.InvalidArgument || f.primary.Load() != 0 {
		t.Fatalf("unselected model reached provider: %v", err)
	}
	execute := func(ctx context.Context, wantFrames bool) error {
		stream, err := control.client.RPC.ExecuteProvider(control.client.Context(ctx), &pb.ProviderRequest{
			Plan: &pb.ProviderPlan{Family: qualified.Family, Node: qualified.Node}, Encoding: pb.Encoding_PROTOBUF, BatchRows: 1,
		})
		if err != nil {
			return err
		}
		seen := false
		for {
			frame, err := stream.Recv()
			if err == io.EOF && seen {
				return nil
			}
			if err != nil {
				return err
			}
			if !wantFrames || frame.GetModel() != qualified.Model {
				return errors.New("unexpected provider frame")
			}
			seen = true
		}
	}
	done := make(chan error, 2)
	for range 2 {
		go func() {
			done <- execute(ctx, true)
		}()
	}
	first, second := <-done, <-done
	if (first != nil && second != nil) || f.primary.Load() != 1 {
		t.Fatalf("expected a single provider dispatch: %v %v, calls=%d", first, second, f.primary.Load())
	}
	control.stop(t)
	f.stop(t)
	f.start(t)
	control.start(t)
	retry, stop := context.WithTimeout(t.Context(), 12*time.Second)
	defer stop()
	if err := execute(retry, false); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("restart must report a consumed original: %v", err)
	}
	if f.primary.Load() != 1 {
		t.Fatal("restart reopened original provider dispatch")
	}
}
