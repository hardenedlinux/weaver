// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"strings"
	"testing"
	"time"
)

type lostTaskAdmission struct {
	pb.GatewayClient
	receipt *pb.TaskAdmissionReceipt
}

func (c *lostTaskAdmission) RegisterOriginalTask(ctx context.Context, r *pb.RegisterOriginalTaskRequest, opts ...grpc.CallOption) (*pb.TaskAdmissionReceipt, error) {
	receipt, err := c.GatewayClient.RegisterOriginalTask(ctx, r, opts...)
	if err == nil && c.receipt == nil {
		c.receipt = proto.Clone(receipt).(*pb.TaskAdmissionReceipt)
		return nil, status.Error(codes.Unavailable, "injected lost task admission reply")
	}
	return receipt, err
}
func TestProviderOriginalTaskOriginLostReplySourceSwitchAndRestart(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	plan := f.plan
	plan.Family = "registered"
	plan.Revision = 1
	plan.Fence = 2
	revision := uint64(0)
	policy := strings.Replace(f.policy, `context.family == "f"`, `["f","registered"].contains(context.family)`, 1)
	if r, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "task-policy", ExpectedRevision: &revision, Fence: 2, Policy: policy, Schema: f.schema}); err != nil || r.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatalf("policy: %v %v", r, err)
	}
	sum := sha256.Sum256([]byte(plan.Body))
	digest, err := plan.Digest()
	if err != nil {
		t.Fatal(err)
	}
	endpoints := map[string]string{}
	var targets []string
	for _, route := range plan.Routes {
		endpoints[route.Target] = route.Endpoint
		targets = append(targets, route.Target)
	}
	task := v1.Task{ProviderProfile: providerProfile(), Family: plan.Family, Principal: "alice", Profile: "p", Nodes: []string{"infer"}, Targets: targets, Endpoints: endpoints, BodyDigests: map[string]string{"infer": hex.EncodeToString(sum[:])}, NodeCostBounds: map[string]uint64{"infer": 4}, StreamContracts: map[string]string{"infer": digest}, Models: []string{"model-a"}, Budget: 8}
	request := &pb.RegisterOriginalTaskRequest{Task: gatewayclient.Task(task), Domains: &pb.DomainBinding{Origin: "original-origin", Budget: "shared", History: "shared", BudgetLimit: 8}, Admission: &pb.TaskAdmission{TaskKey: "upstream-task", OperationId: "original-admission", ExpectedSourceEpoch: 0}}
	lost := &lostTaskAdmission{GatewayClient: f.admin.RPC}
	f.admin.RPC = lost
	if _, err = f.admin.RPC.RegisterOriginalTask(f.admin.Context(ctx), request); status.Code(err) != codes.Unavailable {
		t.Fatalf("lost reply: %v", err)
	}
	original := lost.receipt
	if original == nil {
		t.Fatal("original commit absent")
	}
	if _, err = f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err != nil {
		t.Fatal(err)
	}
	next := secondaryClient(t, f.pki)
	role := sha256.Sum256([]byte(f.admin.Token))
	if _, err = f.admin.RotateSource(ctx, v1.SourceRotation{OperationID: "task-source-switch", ExpectedEpoch: 0, NextCertificate: next.Certificate[0], NextCredentialSHA256: hex.EncodeToString(role[:])}); err != nil {
		t.Fatal(err)
	}
	if _, err = f.admin.RPC.RegisterOriginalTask(f.admin.Context(ctx), request); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("old live source: %v", err)
	}
	restartWithSourceCertificate(t, f, next)
	replay, err := f.admin.RPC.RegisterOriginalTask(f.admin.Context(ctx), request)
	if err != nil || !proto.Equal(replay, original) {
		t.Fatalf("original decision recovery: %v %v", replay, err)
	}
	stale := proto.Clone(request).(*pb.RegisterOriginalTaskRequest)
	stale.Admission.OperationId = "late-worker-command"
	if _, err = f.admin.RPC.RegisterOriginalTask(f.admin.Context(ctx), stale); err == nil {
		t.Fatal("stale epoch acquired fresh decision")
	}
	stale.Admission.ExpectedSourceEpoch = 1
	stale.Task.Family = "new-family"
	stale.Domains.Origin = "new-origin"
	if _, err = f.admin.RPC.RegisterOriginalTask(f.admin.Context(ctx), stale); err == nil {
		t.Fatal("original source task reallocated origin")
	}
	if _, err = f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("original claim replayed")
	}
	view, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: plan.Family})
	if err != nil || view.GetHeld() != 4 || view.GetHistoryCount() != 1 || view.GetStamp().GetTaskKey() != "upstream-task" || f.primary.Load() != 1 {
		t.Fatalf("exposure reset: %v %v calls=%d", view, err, f.primary.Load())
	}
}
