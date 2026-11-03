// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestProviderCompetingCapsCannotReachDispatch(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	plan := f.plan
	plan.Family = "conflicting-caps"
	plan.Body = strings.TrimSuffix(plan.Body, "}") + `,"max_tokens":1000000}`
	digest, err := plan.Digest() // A hash is deliberately not native semantic admission.
	if err != nil {
		t.Fatal(err)
	}
	body := sha256.Sum256([]byte(plan.Body))
	task := v1.Task{ProviderProfile: providerProfile(), Family: plan.Family, Principal: "alice", Profile: plan.Profile, Nodes: []string{plan.Node},
		Targets: []string{}, Endpoints: map[string]string{}, Models: []string{plan.Model}, Budget: 8,
		BodyDigests:     map[string]string{plan.Node: hex.EncodeToString(body[:])},
		StreamContracts: map[string]string{plan.Node: digest}, NodeCostBounds: map[string]uint64{plan.Node: 4}}
	for _, route := range plan.Routes {
		task.Targets = append(task.Targets, route.Target)
		task.Endpoints[route.Target] = route.Endpoint
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Both families are permitted, so a Policy denial cannot mask a missing
	// request-shape guard. The bad request is also exactly source-committed.
	policy := strings.Replace(f.policy, `context.family == "f"`, `(context.family == "f" || context.family == "conflicting-caps")`, 1)
	if policy == f.policy {
		t.Fatal("fixture Policy was not widened")
	}
	revision := uint64(0)
	if result, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "caps-scope", ExpectedRevision: &revision, Fence: 2, Policy: policy, Schema: f.schema}); err != nil || result.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatal("fixture Policy publication", err)
	}
	plan.Revision, plan.Fence = 1, 2
	f.plan.Revision, f.plan.Fence = 1, 2
	if _, err := f.admin.RPC.RegisterTask(f.admin.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(task)}); err != nil {
		t.Fatal(err)
	}
	_, err = f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { t.Error("invalid request released output"); return nil })
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("Rust did not independently reject ambiguous request before Policy/dispatch: %v", err)
	}
	_, err = f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: plan.Family, Node: plan.Node})
	// Operation Inspect deliberately keeps absence/state errors opaque. This is
	// not standalone evidence of absence; the native ledger test reads its hold.
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("invalid request unexpectedly returned an execution receipt: %v", err)
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 || f.denied.Load() != 0 {
		t.Fatal("invalid request reached a provider")
	}
	// The original, independently committed request remains runnable exactly once.
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err != nil {
		t.Fatal(err)
	}
	if f.primary.Load() != 1 || inspect(t, f).Held != 4 {
		t.Fatal("invalid request affected the original claim or hold")
	}
}
