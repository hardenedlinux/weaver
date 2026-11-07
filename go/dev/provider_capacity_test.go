// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestProviderSaturatedExecutionPreservesRevocationAndObservation(t *testing.T) {
	release := make(chan struct{})
	var once sync.Once
	f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		emitChunk(w, "prefix", false)
		select {
		case <-release:
		case <-r.Context().Done():
			return
		}
		emitChunk(w, "tail", false)
		emitChunk(w, "", true)
		fmt.Fprint(w, "data: [DONE]\n\n")
	}, false)
	t.Cleanup(func() { once.Do(func() { close(release) }) })
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	const streams = 16 // Unchanged production default execution capacity.
	task := v1.Task{ProviderProfile: providerProfile(), Family: "f-load", Principal: "alice", Profile: "p", Models: []string{"model-a"}, Budget: streams * 4,
		Endpoints: map[string]string{}, BodyDigests: map[string]string{}, NodeCostBounds: map[string]uint64{}, StreamContracts: map[string]string{}}
	for _, route := range f.plan.Routes {
		task.Targets = append(task.Targets, route.Target)
		task.Endpoints[route.Target] = route.Endpoint
	}
	body := sha256.Sum256([]byte(f.plan.Body))
	plans := make([]v1.ProviderPlan, streams)
	for i := range streams {
		plan := f.plan
		plan.Family, plan.Node, plan.Revision, plan.Fence = task.Family, fmt.Sprintf("infer-%d", i), 1, 2
		digest, err := plan.Digest()
		if err != nil {
			t.Fatal(err)
		}
		task.Nodes = append(task.Nodes, plan.Node)
		task.BodyDigests[plan.Node] = hex.EncodeToString(body[:])
		task.NodeCostBounds[plan.Node] = 4
		task.StreamContracts[plan.Node] = digest
		plans[i] = plan
	}
	revision := uint64(0)
	policy := strings.Replace(f.policy, `context.family == "f" && context.node == "infer"`, `context.family == "f-load"`, 1)
	if policy == f.policy {
		t.Fatal("fixture policy scope not replaced")
	}
	if receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "load-scope", ExpectedRevision: &revision, Fence: 2, Policy: policy, Schema: f.schema}); err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatal(err)
	}
	if _, err := f.admin.RPC.RegisterTask(f.admin.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(task)}); err != nil {
		t.Fatal(err)
	}
	first := make(chan struct{}, streams)
	type outcome struct {
		node  string
		count int
		err   error
	}
	results := make(chan outcome, streams)
	for _, plan := range plans {
		go func() {
			count := 0
			_, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(event *pb.Event) error {
				count++
				if count == 1 {
					first <- struct{}{}
				}
				return nil
			})
			results <- outcome{node: plan.Node, count: count, err: err}
		}()
	}
	for ready := range streams {
		select {
		case <-first:
		case result := <-results:
			t.Fatalf("stream %s ended before revocation after %d events (%d/%d first events observed, %d primary requests): %v",
				result.node, result.count, ready, streams, f.primary.Load(), result.err)
		case <-ctx.Done():
			t.Fatalf("execution capacity did not fill before deadline (%d/%d first events observed, %d primary requests)",
				ready, streams, f.primary.Load())
		}
	}
	// Capacity rejection occurs before considering a duplicate root or its Policy.
	extra, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{Plan: gatewayclient.Plan(plans[0]), Encoding: pb.Encoding_PROTOBUF, BatchRows: 1})
	if err == nil {
		_, err = extra.Recv()
	}
	if status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("expected full execution lane, got %v", err)
	}
	key := &pb.OperationKey{Family: task.Family, Node: plans[0].Node}
	receipt, err := f.client.RPC.Inspect(f.client.Context(ctx), key)
	if err != nil || receipt.Held != streams*4 || receipt.State != "unknown" {
		t.Fatalf("reserved observation lane: %v %v", receipt, err)
	}
	// Fill the operation ingress's sixteen socket slots as well as native execution.
	var idle []*tls.Conn
	t.Cleanup(func() {
		for _, conn := range idle {
			conn.Close()
		}
	})
	for range 15 {
		conn, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp4", f.address, connectionTLS(f))
		if err != nil {
			t.Fatal(err)
		}
		idle = append(idle, conn)
	}
	f.admin.Connection.Close()
	security := connectionTLS(f)
	security.Certificates = []tls.Certificate{f.pki.source}
	f.admin, err = gatewayclient.Dial(ctx, f.sourceAddress, adminToken, security)
	if err != nil {
		t.Fatalf("full operation ingress blocked new source session: %v", err)
	}
	f.admin.RPC = &fixtureReviewer{GatewayClient: f.admin.RPC, key: f.reviewKey}
	revision = 1
	if receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "load-revoke", ExpectedRevision: &revision, Fence: 3, Policy: "forbid(principal,action,resource);", Schema: f.schema}); err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatalf("saturated execution blocked revocation: %v", err)
	}
	once.Do(func() { close(release) })
	for range streams {
		select {
		case result := <-results:
			if result.err == nil || result.count != 1 {
				t.Fatalf("revoked stream released tail: %+v", result)
			}
		case <-ctx.Done():
			t.Fatal("revoked stream did not terminate")
		}
	}
	receipt, err = f.client.RPC.Inspect(f.client.Context(ctx), key)
	if err != nil || receipt.Held != streams*4 || receipt.Events != 1 || receipt.State != "unknown" || f.primary.Load() != streams || f.backup.Load() != 0 {
		t.Fatalf("saturation changed original holds or attempts: %v %v", receipt, err)
	}
}
