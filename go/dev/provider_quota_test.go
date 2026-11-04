// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"testing/quick"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

func TestProviderQuotaUnknownAcrossKeys(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	if err := quick.Check(func(tenantFirst bool) bool {
		userCap, tenantCap := 4, 8
		if tenantFirst {
			userCap, tenantCap = 8, 4
		}
		config, err := json.Marshal(map[string]any{
			"audience": "quota",
			"tenants": map[string]any{"tenant": map[string]any{
				"issuer": "meter", "public_key": strings.Repeat("ab", 32),
				"principals": []string{"alice"}, "rates": [4]uint64{1, 1, 1, 1},
			}},
			"quotas": map[string]any{
				"families": map[string]string{"left": "left-key", "right": "right-key"},
				"keys": map[string]any{
					"left-key":  map[string]any{"principal": "alice", "limit": 4},
					"right-key": map[string]any{"principal": "alice", "limit": 4},
				},
				"users": map[string]int{"alice": userCap}, "tenants": map[string]int{"tenant": tenantCap},
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		f := fixtureWithInvocation(t, func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			emitChunk(w, "partial", false)
		}, false, serverBinary, nil, []string{"WEAVER_METERING=" + string(config)})
		plans := independentProviderPlans(t, f)
		ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
		defer cancel()
		call := func(plan v1.ProviderPlan) error {
			_, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
			return err
		}
		start, done := make(chan struct{}), make(chan error, 2)
		for _, plan := range plans {
			go func() { <-start; done <- call(plan) }()
		}
		close(start)
		if <-done == nil || <-done == nil {
			t.Fatal("partial provider stream reported completion")
		}
		if f.primary.Load() != 1 || f.backup.Load() != 0 {
			t.Fatalf("separate keys bypassed aggregate cap: %d", f.primary.Load())
		}
		f.stop(t)
		f.start(t)
		var held uint64
		for _, plan := range plans {
			view, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: plan.Family})
			if err != nil {
				t.Fatal(err)
			}
			held += view.GetHeld()
			if err := call(plan); err == nil {
				t.Fatal("historical work reopened")
			}
			plan.Model = "other-model"
			plan.Body = strings.Replace(plan.Body, "model-a", plan.Model, 1)
			if err := call(plan); err == nil {
				t.Fatal("model substitution accepted")
			}
		}
		if held != 4 || f.primary.Load() != 1 {
			t.Fatalf("unknown reservation did not survive: held=%d calls=%d", held, f.primary.Load())
		}
		return true
	}, &quick.Config{MaxCount: 4}); err != nil {
		t.Fatal(err)
	}
}
