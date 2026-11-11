// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"math/rand"
	"testing"
	"testing/quick"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
)

// Independent original origins share read custody, never an admission allowance.
// The real TLS providers, native ledger, gRPC receiver and restart all participate.
func TestProviderReadCustodyProperty(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	property := func(room, reverse, arrow bool) bool {
		f := newFixture(t, burstProviderSSE(13), false)
		defer f.stop(t)
		capacity := uint64(4)
		if room {
			capacity = 8
		}
		plans := boundProviderPlans(t, f, capacity)
		if reverse {
			plans[0], plans[1] = plans[1], plans[0]
		}
		encoding := pb.Encoding_PROTOBUF
		if arrow {
			encoding = pb.Encoding_ARROW_IPC
		}
		ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
		defer cancel()
		type result struct {
			rows int
			err  error
		}
		done := make(chan result, 2)
		for _, plan := range plans {
			go func() {
				rows := 0
				_, err := f.client.Execute(ctx, plan, encoding, 1, func(*pb.Event) error { rows++; return nil })
				done <- result{rows, err}
			}()
		}
		success := 0
		for range 2 {
			r := <-done
			if r.err == nil {
				if r.rows != 13 {
					return false
				}
				success++
			} else if room {
				t.Logf("unexpected concurrent stream failure: %v", r.err)
				return false
			}
		}
		expected := capacity / 4
		if uint64(success) != expected || f.primary.Load() != int64(expected) || f.backup.Load() != 0 {
			return false
		}
		f.stop(t)
		f.start(t)
		for _, plan := range plans {
			view, err := f.admin.RPC.InspectExecutionDomains(f.admin.Context(ctx), &pb.OperationKey{Family: plan.Family})
			if err != nil || view.GetHeld() != capacity || view.GetHistoryCount() != expected {
				return false
			}
			if _, err := f.client.Execute(ctx, plan, encoding, 1, func(*pb.Event) error { return nil }); err == nil {
				return false
			}
		}
		return f.primary.Load() == int64(expected) && f.backup.Load() == 0
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 8, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}
