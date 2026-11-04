// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"testing/quick"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestProviderMeteringApplications(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	if err := quick.Check(func(selector uint8) bool {
		checkProviderMetering(t, uint64(selector%5), true)
		return true
	}, &quick.Config{MaxCount: 4}); err != nil {
		t.Fatal(err)
	}
	// Include an original with zero remainder regardless of generated inputs.
	checkProviderMetering(t, 4, true)
	checkProviderMetering(t, 0, false)
}

func checkProviderMetering(t *testing.T, charged uint64, completed bool) {
	t.Helper()
	type tenant struct {
		Issuer     string    `json:"issuer"`
		PublicKey  string    `json:"public_key"`
		Principals []string  `json:"principals"`
		Rates      [4]uint64 `json:"rates"`
	}
	rates := [4]uint64{1_000_000, 0, 0, 1_000_000}
	keys := map[string]ed25519.PrivateKey{}
	tenants := map[string]tenant{}
	for id, principal := range map[string]string{"alpha": "alice", "beta": "bob"} {
		public, private, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		keys[id] = private
		tenants[id] = tenant{id + "-meter", hex.EncodeToString(public), []string{principal}, rates}
	}
	config, err := json.Marshal(map[string]any{"audience": "metering-test", "tenants": tenants})
	if err != nil {
		t.Fatal(err)
	}
	handler := completeSSE
	if !completed {
		handler = func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			emitChunk(w, "partial", false)
		}
	}
	f := fixtureWithInvocation(t, handler, false, serverBinary, nil, []string{"WEAVER_METERING=" + string(config)})
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	_, err = f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
	if (err == nil) != completed {
		t.Fatalf("unexpected provider outcome: %v", err)
	}
	original := inspect(t, f)
	expectedState := "unknown"
	if completed {
		expectedState = "complete"
	}
	if original.GetState() != expectedState || original.GetHeld() != 4 {
		t.Fatalf("original reservation: %v", original)
	}
	bound, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: f.plan.Family})
	if err != nil {
		t.Fatal(err)
	}
	formula, err := v1.MeteringFormulaDigest(rates)
	if err != nil {
		t.Fatal(err)
	}
	usage, err := v1.NormalizeProviderTokens(charged+2, 1, 1, 0, true)
	if err != nil {
		t.Fatal(err)
	}
	evidence := v1.TerminalUsage{
		Audience: "metering-test", Tenant: "alpha", Issuer: "alpha-meter", Application: "application",
		Family: f.plan.Family, Node: f.plan.Node, Origin: bound.GetStamp().GetOrigin(), Target: original.GetTarget(),
		PlanDigest: original.GetDigest(), FormulaDigest: formula, TerminalDigest: strings.Repeat("a", 64), Tokens: usage,
	}
	wire := func(u v1.TerminalUsage) *pb.MeteringReceipt {
		t.Helper()
		signature, err := u.Sign(keys[u.Tenant])
		if err != nil {
			t.Fatal(err)
		}
		return &pb.MeteringReceipt{
			Audience: u.Audience, Tenant: u.Tenant, Issuer: u.Issuer, Application: u.Application,
			Family: u.Family, Node: u.Node, Origin: u.Origin, Target: u.Target,
			PlanDigest: u.PlanDigest, FormulaDigest: u.FormulaDigest, TerminalDigest: u.TerminalDigest,
			Tokens: u.Tokens[:], Signature: signature,
		}
	}
	apply := func(u v1.TerminalUsage) (*pb.MeteringApplication, error) {
		return f.admin.RPC.ApplyMetering(f.admin.Context(ctx), wire(u))
	}
	other := f.plan
	other.Family = "other-tenant"
	task := profileTask(t, other, *providerProfile())
	task.Principal = "bob"
	if _, err := f.admin.RPC.RegisterTask(f.admin.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(task)}); err != nil {
		t.Fatal(err)
	}
	migration, err := f.admin.RPC.MigrateExecutionDomains(f.admin.Context(ctx), &pb.DomainMigration{
		OperationId: "cross-tenant", BudgetFrom: f.plan.Family, HistoryFrom: f.plan.Family,
		BudgetTo: other.Family, HistoryTo: other.Family,
		BudgetFromEpoch: 1, BudgetToEpoch: 1, HistoryFromEpoch: 1, HistoryToEpoch: 1,
	})
	if err != nil || migration.GetCommitted() {
		t.Fatalf("cross-tenant domain union: %v %v", migration, err)
	}
	if !completed {
		if _, err := apply(evidence); status.Code(err) != codes.PermissionDenied || inspect(t, f).GetHeld() != 4 {
			t.Fatalf("signed but unresolved usage released exposure: %v", err)
		}
		return
	}
	wrong := evidence
	wrong.Tenant, wrong.Issuer = "beta", "beta-meter"
	if _, err := apply(wrong); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("other tenant signature admitted: %v", err)
	}
	forged := wire(evidence)
	forged.Tokens[0]++
	if _, err := f.admin.RPC.ApplyMetering(f.admin.Context(ctx), forged); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("altered token count admitted: %v", err)
	}
	loss := &meteringReplyLoss{GatewayClient: f.admin.RPC}
	if _, err := loss.ApplyMetering(f.admin.Context(ctx), wire(evidence)); status.Code(err) != codes.Unavailable {
		t.Fatalf("metering reply loss not injected: %v", err)
	}
	first := loss.committed
	if first.GetCharged() != charged || first.GetReleased() != 4-charged {
		t.Fatalf("original application: %v", first)
	}
	f.stop(t)
	f.start(t)
	recovered, err := apply(evidence)
	if err != nil || !proto.Equal(recovered, first) {
		t.Fatalf("original application was not recovered: %v %v", recovered, err)
	}
	duplicate := evidence
	duplicate.Application = "replacement"
	if _, err := apply(duplicate); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("replacement application id admitted: %v", err)
	}
	after, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: f.plan.Family})
	if err != nil || after.GetHeld() != charged || after.GetHistoryCount() != 1 || f.primary.Load() != 1 {
		t.Fatalf("account exposure or original history changed: %v %v", after, err)
	}
}

type meteringReplyLoss struct {
	pb.GatewayClient
	committed *pb.MeteringApplication
}

func (c *meteringReplyLoss) ApplyMetering(ctx context.Context, req *pb.MeteringReceipt, options ...grpc.CallOption) (*pb.MeteringApplication, error) {
	outcome, err := c.GatewayClient.ApplyMetering(ctx, req, options...)
	if err != nil {
		return nil, err
	}
	c.committed = outcome
	return nil, status.Error(codes.Unavailable, "injected loss after real metering commit")
}
