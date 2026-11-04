// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/routing"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestProviderModuleSelectionBindsOriginal(t *testing.T) {
	f := newFixture(t, completeSSE, false)
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
	bundle.Routing = []routing.Selection{{
		Node: qualified.Node, AllowedModules: []string{"basic", "premium"}, Required: []string{"quality"},
		MaxLatencyMillis: 100, MaxProcurementCost: 100,
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
	if _, err := control.client.Execute(ctx, cheap, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); status.Code(err) != codes.PermissionDenied || f.primary.Load() != 0 {
		t.Fatalf("unselected model reached provider: %v", err)
	}
	receipt, err := control.client.Execute(ctx, qualified, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
	if err != nil || receipt.GetState() != "complete" || f.primary.Load() != 1 {
		t.Fatalf("selected route not executed: %v %v", receipt, err)
	}
}
