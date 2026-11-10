// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && schemeintegration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/routing"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type lostCatalogReply struct{ pb.GatewayClient }

func (c lostCatalogReply) PublishProviderCatalog(ctx context.Context, req *pb.ProviderCatalogChange, opts ...grpc.CallOption) (*pb.ProviderCatalogSnapshot, error) {
	if _, err := c.GatewayClient.PublishProviderCatalog(ctx, req, opts...); err != nil {
		return nil, err
	}
	return nil, status.Error(codes.Unavailable, "catalog reply lost after committed RPC")
}

func TestProviderModuleSelectionBindsOriginal(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	for _, mode := range []string{"complete", "partial", "deny"} {
		t.Run(mode, func(t *testing.T) { checkImportedProvider(t, mode, false) })
	}
}
func TestProviderRustDirectCatalogSelection(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	for _, mode := range []string{"complete", "alternate", "partial", "deny"} {
		t.Run(mode, func(t *testing.T) { checkImportedProvider(t, mode, true) })
	}
}
func checkImportedProvider(t *testing.T, mode string, direct bool) {
	t.Helper()
	handler := completeSSE

	if mode == "partial" {
		handler = func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			emitChunk(w, "partial", false)
		}
	}
	f := fixtureWithInvocation(t, handler, false, serverBinary, nil, nil, func(plan v1.ProviderPlan) string {
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
	if _, err := f.client.RPC.ComposeSource(f.client.Context(t.Context()), &pb.SourceCompositionRequest{}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("operation caller entered semantic composition: %v", err)
	}
	if _, err := f.admin.RPC.ComposeSource(f.admin.Context(t.Context()), &pb.SourceCompositionRequest{UseCatalog: true, ExpectedCatalogVersion: "unexpected"}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("stale catalog coordinate entered composition: %v", err)
	}
	if direct {
		if _, err := f.client.RPC.RegisterPublishedTask(f.client.Context(t.Context()), &pb.RegisterPublishedTaskRequest{SourceScope: &pb.SourceCompositionRequest{}}); status.Code(err) != codes.PermissionDenied {
			t.Fatalf("operation caller declared source scope: %v", err)
		}
	}
	bundle := controlBundle(t, f)
	selected := append([]string(nil), bundle.Governance.OpenNodes[:1]...)
	bundle.Governance.OpenNodes = selected
	task := &bundle.Tasks[0]
	task.Nodes, task.Models = selected, []string{"model-a", "model-b"}
	task.BodyDigests, task.StreamContracts = nil, nil
	delete(task.NodeCostBounds, "next")
	qualified := bundle.Plans[0]
	for _, route := range qualified.Routes {
		if route.Target == "primary" {
			qualified.Routes = []v1.ProviderRoute{route}
			break
		}
	}
	if mode == "deny" {
		bundle.Publication.Policy += `
forbid(principal, action == Weaver::Action::"invokeProvider", resource) when { context.family == "control" };`
	}
	invalid := qualified
	invalid.Body = `{}` // Ineligible offer must not suppress the valid module.
	cheap := qualified
	cheap.Model = "model-b"
	cheap.Body = strings.Replace(cheap.Body, "model-a", "model-b", 1)
	chosen := qualified
	if mode == "alternate" {
		cheap = qualified
		cheap.Body = strings.Replace(cheap.Body, "hello", "alternate", 1)
		chosen = cheap
	}
	bundle.Plans = nil
	bundle.SelectOnRequest = true
	bundle.Routing = []routing.Selection{{
		Node: qualified.Node, AllowedModules: []string{"basic", "premium"}, Required: []string{"quality"},
		MaxLatencyMillis: 100, MaxProcurementCost: 100, UserTokenRates: [4]uint64{0, 0, 0, 100000},
		Candidates: []routing.Candidate{
			{Module: "premium", Capabilities: []string{"quality"}, LatencyMillis: 1, TokenBounds: [4]uint64{64, 0, 0, 32}, Plan: invalid},
			{Module: "basic", LatencyMillis: 10, TokenBounds: [4]uint64{64, 0, 0, 32}, Plan: cheap},
			{Module: "premium", Capabilities: []string{"quality"}, LatencyMillis: 40, ProcurementRates: [4]uint64{1_000_000}, TokenBounds: [4]uint64{64, 0, 0, 32}, Plan: qualified},
		},
	}}
	control := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	if direct {
		control.prepare(t)
		control.client = f.client
	} else {
		control.start(t)
		t.Cleanup(func() { control.stop(t) })
	}
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	source := f.admin
	entry := func(rate uint64) map[string]any {
		userRates := [4]uint64{0, 0, 0, 100000}
		if rate == 500000 {
			userRates[3] = 120000
		}
		formula, err := v1.MeteringFormulaDigest(userRates)
		if err != nil {
			t.Fatal(err)
		}
		return map[string]any{
			"module": "premium", "capabilities": []string{"quality"}, "latency_millis": 40,
			"user_rates": userRates,
			"quote": map[string]any{"version": "purchase", "tenant": "tenant", "formula_digest": formula,
				"procurement_rates": [4]uint64{rate}, "token_bounds": [4]uint64{64, 0, 0, 32}},
		}
	}
	chosenDigest, _ := chosen.Digest()
	change := func(parent string, rate uint64) *pb.ProviderCatalogChange {
		metadata, err := json.Marshal(entry(rate))
		if err != nil {
			t.Fatal(err)
		}
		litellm, err := json.Marshal(map[string]any{"model_list": []any{
			map[string]any{"model_name": "premium", "litellm_params": map[string]string{
				"model": "openai/" + chosen.Model, "api_base": strings.TrimSuffix(chosen.Routes[0].Endpoint, "/chat/completions"),
				"api_key": "os.environ/WEAVER_TEST_KEY",
			}},
		}})
		if err != nil {
			t.Fatal(err)
		}
		record, err := config.ImportProviderCatalog(litellm, config.ProfileJSON, config.ProviderImportReview{
			Parent: parent, Bindings: map[string]config.ProviderImportBinding{
				"premium": {Plan: chosen, Credential: "os.environ/WEAVER_TEST_KEY", Entry: metadata},
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		return &pb.ProviderCatalogChange{Record: record}
	}
	publish := func(change *pb.ProviderCatalogChange) (*pb.ProviderCatalogSnapshot, error) {
		return source.RPC.PublishProviderCatalog(source.Context(ctx), change)
	}
	initial := change("", 1000000)
	firstCatalog, err := publish(initial)
	if err != nil {
		t.Fatal(err)
	}
	second := change(firstCatalog.Version, 500000)
	lost := lostCatalogReply{source.RPC}
	if _, err := lost.PublishProviderCatalog(source.Context(ctx), second); status.Code(err) != codes.Unavailable {
		t.Fatalf("catalog reply loss: %v", err)
	}
	current, err := publish(second)
	if err != nil || current.GetVersion() == firstCatalog.Version {
		t.Fatalf("catalog update: %v", err)
	}
	historical, err := publish(initial)
	if err != nil || historical.GetVersion() != firstCatalog.Version {
		t.Fatalf("catalog replay: %v", err)
	}
	if _, err := publish(change(firstCatalog.Version, 800000)); err == nil {
		t.Fatal("stale parent published")
	}
	stale := f.plan
	stale.Revision, stale.Fence = qualified.Revision, qualified.Fence
	stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{
		Plan: gatewayclient.Plan(stale), Encoding: pb.Encoding_PROTOBUF, BatchRows: 1, CatalogVersion: firstCatalog.Version,
	})
	if err == nil {
		_, err = stream.Recv()
	}
	if status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 0 {
		t.Fatalf("stale quote admitted: %v", err)
	}
	expectedCode := codes.InvalidArgument
	if direct {
		expectedCode = codes.FailedPrecondition
	}
	unselected := cheap
	if mode == "alternate" {
		unselected = qualified
	}
	if _, err := control.client.Execute(ctx, unselected, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); status.Code(err) != expectedCode || f.primary.Load() != 0 {
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
			if !wantFrames || frame.GetModel() != chosen.Model {
				return errors.New("unexpected provider frame")
			}
			seen = true
		}
	}
	const contenders = 4
	done := make(chan error, contenders)
	for range contenders {
		go func() {
			done <- execute(ctx, true)
		}()
	}
	var successes int
	for range contenders {
		if <-done == nil {
			successes++
		}
	}
	if mode == "deny" {
		if successes != 0 || f.primary.Load() != 0 {
			t.Fatalf("import bypassed Cedar invocation: successes=%d calls=%d", successes, f.primary.Load())
		}
		if direct {
			next := secondaryClient(t, f.pki)
			token := sha256.Sum256([]byte(f.admin.Token))
			if _, err := f.admin.RotateSource(ctx, v1.SourceRotation{OperationID: "retire-routing-source", ExpectedEpoch: 0, NextCertificate: next.Certificate[0], NextCredentialSHA256: hex.EncodeToString(token[:])}); err != nil {
				t.Fatal(err)
			}
			if err := execute(ctx, false); status.Code(err) != codes.FailedPrecondition {
				t.Fatalf("retired source reused cached projection: %v", err)
			}
			f.stop(t)
			f.start(t)
			control.client = f.client
			if err := execute(ctx, false); status.Code(err) != codes.FailedPrecondition {
				t.Fatalf("restart restored retired source: %v", err)
			}
			if f.primary.Load() != 0 {
				t.Fatal("retired source sent provider traffic")
			}
		}
		return
	}
	if ((mode == "complete" || mode == "alternate") && successes != 1) || (mode == "partial" && successes != 0) || f.primary.Load() != 1 {
		t.Fatalf("expected a single provider dispatch: successes=%d calls=%d", successes, f.primary.Load())
	}
	withdrawal, err := json.Marshal(map[string]any{"parent": current.Version, "entries": map[string]any{}})
	if err != nil {
		t.Fatal(err)
	}
	withdrawn := current
	if mode == "complete" || mode == "alternate" {
		withdrawn, err = publish(&pb.ProviderCatalogChange{Record: withdrawal})
		if err != nil {
			t.Fatal(err)
		}
	}
	if !direct {
		control.stop(t)
	}
	f.stop(t)
	f.start(t)
	if direct {
		control.client = f.client
	} else {
		control.start(t)
	}
	retry, stop := context.WithTimeout(t.Context(), 12*time.Second)
	defer stop()
	if err := execute(retry, false); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("restart must report a consumed original: %v", err)
	}
	recovered, err := f.admin.RPC.InspectProviderCatalog(f.admin.Context(retry), &pb.Empty{})
	if err != nil || recovered.GetVersion() != withdrawn.Version {
		t.Fatalf("catalog head recovery: %v", err)
	}
	original, err := control.client.RPC.Inspect(control.client.Context(retry), &pb.OperationKey{Family: qualified.Family, Node: qualified.Node})
	if err != nil || original.GetReserved() != 4 || original.GetHeld() != 4 || original.GetDigest() != chosenDigest {
		t.Fatalf("original reservation changed: %v %v", original, err)
	}
	if (mode == "partial" && original.GetState() != "unknown") || f.primary.Load() != 1 {
		t.Fatal("restart reopened original provider dispatch")
	}
}
