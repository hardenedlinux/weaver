// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && schemeintegration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func hardFactFeedSetting(t *testing.T, f *fixture, family, root string, dependencies [][2]string, workflow map[string]string, workflowSchema string, selectors [][3]string, path ...string) string {
	t.Helper()
	certificate, err := x509.ParseCertificate(f.pki.source.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	leaf := sha256.Sum256(certificate.Raw)
	key := sha256.Sum256(certificate.RawSubjectPublicKeyInfo)
	token := sha256.Sum256([]byte(adminToken))
	config := map[string]any{
		"domain": "availability",
		"authority": map[string]any{"epoch": 0, "identity": map[string]string{
			"certificate_sha256": hex.EncodeToString(leaf[:]),
			"public_key_sha256":  hex.EncodeToString(key[:]),
			"credential_sha256":  hex.EncodeToString(token[:]),
		}},
		"family": family, "root": root, "dependencies": dependencies,
	}
	if workflow != nil {
		config["workflow"] = workflow
	}
	if workflowSchema == "weaver.session-dag.v1" || workflowSchema == "weaver.session-choice.v1" || workflowSchema == "weaver.session-nested.v1" {
		config["workflow_dag"] = true
	}
	if workflowSchema == "weaver.session-choice.v1" {
		config["workflow_choice"] = true
	}
	if len(selectors) != 0 {
		config["workflow_selectors"] = selectors
	}
	if len(path) != 0 {
		config["workflow_path"] = path
	}
	feed, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	return "WEAVER_HARD_FACT_FEED=" + string(feed)
}

func TestProviderControlHardFactWithdrawalRestartAndABA(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	f.env = append(f.env, hardFactFeedSetting(t, f, f.plan.Family, f.plan.Node, [][2]string{}, nil, "", nil))
	compiledControlSources(false).configure(t, f, controlBundle(t, f))

	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	blocked := func(label string) {
		t.Helper()
		_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error {
			t.Errorf("%s emitted a provider event", label)
			return nil
		})
		if status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 0 || f.backup.Load() != 0 {
			t.Fatalf("%s: expected hard fact barrier, got %v", label, err)
		}
	}
	stage := func(intent *pb.HardFactIntent) *pb.HardFactBarrier {
		t.Helper()
		barrier, err := f.admin.RPC.StageHardFact(f.admin.Context(ctx), intent)
		if err != nil || barrier.GetFloor() != intent.ExpectedFloor+1 || barrier.GetRevision() != intent.Revision {
			t.Fatalf("stage hard fact: %v %v", barrier, err)
		}
		return barrier
	}
	resolve := func(barrier *pb.HardFactBarrier) *pb.FactBarrierResolution {
		t.Helper()
		result, err := f.admin.RPC.ResolveHardFact(f.admin.Context(ctx), barrier)
		if err != nil || !proto.Equal(barrier, result.GetBarrier()) ||
			len(result.GetAffected()) != 1 || result.GetAffected()[0] != f.plan.Node {
			t.Fatalf("resolve hard fact: %v %v", result, err)
		}
		return result
	}

	blocked("before first admitted fact")
	intent := &pb.HardFactIntent{OperationId: "fact-a", Domain: "availability", Revision: 1,
		PreviousSnapshot: strings.Repeat("0", 64), Available: proto.Bool(true)}
	if _, err := f.client.RPC.StageHardFact(f.client.Context(ctx), intent); err == nil {
		t.Fatal("operation credential staged a hard fact")
	}
	foreignDomain := proto.CloneOf(intent)
	foreignDomain.Domain = "unadmitted"
	if _, err := f.admin.RPC.StageHardFact(f.admin.Context(ctx), foreignDomain); err == nil {
		t.Fatal("generic source credential staged a fact outside its feed")
	}
	a := stage(intent)
	forged := proto.CloneOf(a)
	forged.PendingPrefix = strings.Repeat("0", 64)
	if _, err := f.admin.RPC.ResolveHardFact(f.admin.Context(ctx), forged); err == nil {
		t.Fatal("forged pending prefix was accepted")
	}
	resolve(a)
	withdrawal := &pb.HardFactIntent{OperationId: "fact-b", Domain: intent.Domain, Revision: 2,
		PreviousSnapshot: a.Snapshot, ExpectedFloor: a.Floor, Available: proto.Bool(false)}
	b := stage(withdrawal)
	blocked("withdrawal pending")
	f.stop(t)
	f.start(t)
	if retry := stage(withdrawal); !proto.Equal(retry, b) {
		t.Fatal("restart or lost stage reply changed the durable barrier")
	}
	blocked("withdrawal pending after restart")
	resolve(b)
	blocked("withdrawal resolved")

	restoration := &pb.HardFactIntent{OperationId: "fact-a-again", Domain: intent.Domain, Revision: 3,
		PreviousSnapshot: b.Snapshot, ExpectedFloor: b.Floor, Available: proto.Bool(true)}
	aAgain := stage(restoration)
	if aAgain.Snapshot == a.Snapshot || aAgain.PendingPrefix == a.PendingPrefix {
		t.Fatal("A-B-A reused an old cut")
	}
	resolve(a)
	blocked("old exact receipt replay cannot clear a newer pending barrier")
	resolve(aAgain)
	_, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
	if err != nil || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatalf("restored fact did not permit normal guarded provider execution: %v", err)
	}
}
