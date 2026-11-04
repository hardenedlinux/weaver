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
	"fmt"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/routing"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func profileTask(t testing.TB, plan v1.ProviderPlan, profile v1.ProviderProfile) v1.Task {
	t.Helper()
	body := sha256.Sum256([]byte(plan.Body))
	digest, err := plan.Digest()
	if err != nil {
		t.Fatal(err)
	}
	task := v1.Task{Family: plan.Family, Principal: "alice", Profile: plan.Profile, ProviderProfile: &profile,
		Nodes: []string{plan.Node}, Targets: []string{}, Endpoints: map[string]string{},
		BodyDigests:     map[string]string{plan.Node: hex.EncodeToString(body[:])},
		StreamContracts: map[string]string{plan.Node: digest}, NodeCostBounds: map[string]uint64{plan.Node: 4}, Models: []string{plan.Model}, Budget: 8}
	for _, route := range plan.Routes {
		task.Targets = append(task.Targets, route.Target)
		task.Endpoints[route.Target] = route.Endpoint
	}
	return task
}

func TestProviderSourceProfileAndCedarBindFinalSendAcrossRestart(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	raw, err := os.ReadFile(filepath.Join(root(t), "prod/policies/provider/profile.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	profile, err := config.DecodeProviderProfile(raw, config.ProfileYAML)
	if err != nil {
		t.Fatal(err)
	}
	profile.ID, profile.MaxOutputTokens, profile.MaxMessages, profile.MaxBodyBytes = "yaml-profile", 64, 1, 4096
	digest, err := profile.Digest()
	if err != nil {
		t.Fatal(err)
	}
	plan := f.plan
	plan.Family, plan.Profile, plan.ProfileCommitment, plan.Revision, plan.Fence = "profile-bound", profile.ID, digest, 1, 2
	plan.Body = strings.Replace(plan.Body, `"max_completion_tokens":32`, `"max_completion_tokens":8`, 1)
	task := profileTask(t, plan, profile)
	policy := f.policy + fmt.Sprintf(`
permit(principal == Weaver::Principal::"alice", action in [Weaver::Action::"admitProvider", Weaver::Action::"invokeProvider", Weaver::Action::"emitProvider"], resource)
when { ["profile-bound","policy-bound"].contains(context.family) && context.node == "infer" &&
context.profile == %q && context.profile_digest == %q && context.protocol == "openai.chat-text-sse.v1" &&
context.output_token_limit <= 16 && context.message_count == 1 };`, profile.ID, digest)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	parent := uint64(0)
	if result, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "profile-policy", ExpectedRevision: &parent, Fence: 2, Policy: policy, Schema: f.schema}); err != nil || result.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatal("profile Policy", err)
	}
	if _, err := f.admin.RPC.RegisterTask(f.admin.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(task)}); err != nil {
		t.Fatal(err)
	}
	// Profile validation permits this body, but fresh Cedar must still deny it.
	denied := plan
	denied.Family, denied.Body = "policy-bound", f.plan.Body
	deniedTask := profileTask(t, denied, profile)
	if _, err := routing.CompileProvider(deniedTask, denied, v1.View{Revision: 1, Fence: 2}); err != nil {
		t.Fatal("schema unexpectedly denied Policy control", err)
	}
	if _, err := f.admin.RPC.RegisterTask(f.admin.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(deniedTask)}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.client.Execute(ctx, denied, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { t.Error("Policy-denied output"); return nil }); err == nil {
		t.Fatal("source profile substituted for Cedar authorization")
	}
	wrong := plan
	wrong.ProfileCommitment = f.plan.ProfileCommitment
	if _, err := f.client.Execute(ctx, wrong, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("wrong semantic commitment admitted")
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 || f.denied.Load() != 0 {
		t.Fatal("invalid schema/Policy reached transport")
	}
	compiled, err := routing.CompileProvider(task, plan, v1.View{Revision: 1, Fence: 2})
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := f.client.Execute(ctx, compiled, pb.Encoding_ARROW_IPC, 2, func(*pb.Event) error { return nil })
	if err != nil || receipt.GetHeld() != 4 || f.primary.Load() != 1 {
		t.Fatal("valid registered profile", receipt, err)
	}
	// Reissuing the original registration repairs no claim and refunds nothing.
	f.stop(t)
	f.start(t)
	if _, err := f.admin.RPC.RegisterTask(f.admin.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(task)}); err != nil {
		t.Fatal("lost registration reply recovery", err)
	}
	if _, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("restart duplicated original provider attempt")
	}
	observed, err := f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: plan.Family, Node: plan.Node})
	if err != nil || observed.GetHeld() != 4 || f.primary.Load() != 1 {
		t.Fatal("recovery changed original hold", observed, err)
	}
}

func TestProviderSourceCommittedExtensionsCannotBypassProfile(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	policy := f.policy + `
permit(principal == Weaver::Principal::"alice", action in [Weaver::Action::"admitProvider", Weaver::Action::"invokeProvider", Weaver::Action::"emitProvider"],resource)
when { context.profile == "p" && context.node == "infer" && context.model == "model-a" };`
	parent := uint64(0)
	if result, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "schema-policy", ExpectedRevision: &parent, Fence: 2, Policy: policy, Schema: f.schema}); err != nil || result.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatal(err)
	}
	patches := []string{`{"max_output_tokens":1000000}`, `{"scope":"forged"}`, `{"response_format":{"type":"json_schema"}}`,
		`{"messages":[{"role":"tool","content":"proposal"}]}`, `{"stream_options":{"include_usage":true,"scope":"forged"}}`}
	for i, patch := range patches {
		plan := f.plan
		plan.Family, plan.Revision, plan.Fence = fmt.Sprintf("schema-%d", i), 1, 2
		body, err := v1.Decode[map[string]json.RawMessage]([]byte(plan.Body))
		if err != nil {
			t.Fatal(err)
		}
		changes, err := v1.Decode[map[string]json.RawMessage]([]byte(patch))
		if err != nil {
			t.Fatal(err)
		}
		for key, value := range changes {
			body[key] = value
		}
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		plan.Body = string(encoded)
		task := profileTask(t, plan, *providerProfile())
		if _, err := f.admin.RPC.RegisterTask(f.admin.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(task)}); err != nil {
			t.Fatal(err)
		}
		if _, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { t.Error("unsupported profile output"); return nil }); err == nil {
			t.Fatal("unsupported source-committed extension admitted")
		}
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 || f.denied.Load() != 0 {
		t.Fatal("unsupported extension reached provider")
	}
	f.plan.Revision, f.plan.Fence = 1, 2
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err != nil {
		t.Fatal(err)
	}
	if f.primary.Load() != 1 || inspect(t, f).Held != 4 {
		t.Fatal("invalid extension changed original claim")
	}
}
