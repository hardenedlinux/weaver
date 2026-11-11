// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"fmt"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

// This is an additional cohort, not a replacement for the frozen 13-frame pair.
// Three admissions become offered only after the first old frame is received.
// Native scheduling, TLS, currentness and commits remain real and unpaused.
func BenchmarkProviderAdmissionOverlap(b *testing.B) {
	image := wifImage(b, true)
	comparison := deliveryComparison{staggered: true, labels: [2]string{"early-close", "selected-close"}, controls: [2][]string{{"WEAVER_TEST_EARLY_ADMISSION_BARRIER=1"}, nil}}
	for _, loaded := range []bool{false, true} {
		b.Run(fmt.Sprintf("shared=true/pressure=%t/ranges=64", loaded), func(b *testing.B) { benchmarkProviderDeliveryComparison(b, image, true, loaded, comparison) })
	}
}

func measureAdmissionOverlapWave(b *testing.B, f *fixture, plans []v1.ProviderPlan, ranges int) ([]domainStreamSample, time.Duration) {
	b.Helper()
	ctx, cancel := context.WithTimeout(b.Context(), 12*time.Second)
	defer cancel()
	first := make(chan struct{})
	type result struct {
		sample domainStreamSample
		events int
		err    error
	}
	results := make(chan result, len(plans))
	began := time.Now()
	for i, plan := range plans {
		go func() {
			if i != 0 {
				select {
				case <-first:
				case <-ctx.Done():
					results <- result{err: ctx.Err()}
					return
				}
			}
			at := time.Now()
			var onFirst func()
			if i == 0 {
				onFirst = func() { close(first) }
			}
			n, timing, err := readDomainProgramStreamObserved(ctx, f.client, plan, pb.Encoding_PROTOBUF, 1, onFirst)
			if err == nil && timing.frames != ranges {
				err = fmt.Errorf("missing overlap frames: %d", timing.frames)
			}
			results <- result{domainStreamSample{family: plan.Family, latency: time.Since(at), transport: timing}, n, err}
		}()
	}
	var streams []domainStreamSample
	for range plans {
		r := <-results
		if r.err != nil || r.events != ranges {
			b.Fatal("actual admission overlap did not complete", r.events, r.err)
		}
		streams = append(streams, r.sample)
	}
	wall := time.Since(began)
	verifyDomainProgramWave(b, ctx, f, plans, ranges, true)
	return streams, wall
}
