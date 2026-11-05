// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Both arms use one image, the same durable guards and the same 128-stream
// workload. The control commits each range; the candidate publishes one
// bounded snapshot. Both retain semantic invalidation and the final owner gate.
func BenchmarkProviderDeliveryJoin(b *testing.B) {
	image := wifImage(b, true)
	for _, shared := range []bool{true, false} {
		for _, loaded := range []bool{false, true} {
			b.Run(fmt.Sprintf("shared=%t/pressure=%t", shared, loaded), func(b *testing.B) {
				benchmarkProviderDeliveryJoin(b, image, shared, loaded)
			})
		}
	}
}

func benchmarkProviderDeliveryJoin(b *testing.B, image string, shared, loaded bool) {
	benchmarkProviderDeliveryComparison(b, image, shared, loaded, deliveryComparison{
		labels:   [2]string{"single-range", "published-snapshot"},
		controls: [2][]string{{"WEAVER_TEST_SINGLE_RANGE_COMMIT=1"}, nil}, queues: [2]int{13, 4},
	})
}

type deliveryComparison struct {
	labels   [2]string
	controls [2][]string
	queues   [2]int
}

func BenchmarkProviderLifecycleFootprint(b *testing.B) {
	image := wifImage(b, true)
	comparison := deliveryComparison{labels: [2]string{"full-domain", "origin-cut"},
		controls: [2][]string{{"WEAVER_TEST_FULL_LIFECYCLE_INVALIDATION=1", "WEAVER_TEST_EXCLUSIVE_PROVIDER_READS=1"}, {"WEAVER_TEST_EXCLUSIVE_PROVIDER_READS=1"}}, queues: [2]int{4, 4}}
	for _, shared := range []bool{true, false} {
		for _, loaded := range []bool{false, true} {
			b.Run(fmt.Sprintf("shared=%t/pressure=%t", shared, loaded), func(b *testing.B) { benchmarkProviderDeliveryComparison(b, image, shared, loaded, comparison) })
		}
	}
}

func BenchmarkProviderReadCustody(b *testing.B) {
	image := wifImage(b, true)
	comparison := deliveryComparison{labels: [2]string{"exclusive-reads", "shared-reads"},
		controls: [2][]string{{"WEAVER_TEST_EXCLUSIVE_PROVIDER_READS=1"}, nil}, queues: [2]int{4, 4}}
	for _, shared := range []bool{true, false} {
		for _, loaded := range []bool{false, true} {
			b.Run(fmt.Sprintf("shared=%t/pressure=%t", shared, loaded), func(b *testing.B) { benchmarkProviderDeliveryComparison(b, image, shared, loaded, comparison) })
		}
	}
}

func benchmarkProviderDeliveryComparison(b *testing.B, image string, shared, loaded bool, comparison deliveryComparison) {
	b.Helper()
	b.StopTimer()
	const ranges, parallel, samples = 13, 4, 128
	var arms [2]providerTailArm
	for i := range arms {
		env := []string{"WEAVER_STORAGE_JOURNAL=mvcc", "WEAVER_TEST_PROVIDER_TAIL=1", "WEAVER_TEST_PROVIDER_SCOPE_TRACE=1"}
		env = append(env, comparison.controls[i]...)
		arms[i].fixture = domainBenchmarkFixture(b, image, env, burstProviderSSE(ranges))
	}
	var stopPressure func() (time.Duration, time.Duration)
	if loaded {
		stopPressure = startProviderPressure(b, max(1, runtime.NumCPU()/2))
	}
	b.StartTimer()
	for wave := range b.N * samples / parallel {
		for _, i := range []int{wave % 2, 1 - wave%2} {
			arm := &arms[i]
			plans := registerDomainProgramWave(b, arm.fixture, wave, parallel, shared)
			streams, wall := measureDomainProgramWave(b, arm.fixture, plans, ranges, shared)
			arm.streams = append(arm.streams, streams...)
			arm.wall += wall
		}
	}
	b.StopTimer()
	if stopPressure != nil {
		cpu, wall := stopPressure()
		b.ReportMetric(cpu.Seconds()/wall.Seconds(), "pressure-cpu-equivalents")
	}
	b.ReportMetric(0, "ns/op")
	for i, label := range comparison.labels {
		arm := &arms[i]
		reportProviderTailArm(b, arm, label)
		queues := comparison.queues[i]
		reportScheduledEncoding(b, arm, label, ranges, (ranges+3)/4, queues, shared)
		reportDeliveryJoin(b, arm, label)
		arm.fixture.stop(b)
	}
}

type deliverySample struct {
	first                  uint64
	acknowledged, accepted int64
	wait, turn             time.Duration
	refresh                uint64
}

func readDeliverySamples(b testing.TB, f *fixture) map[string][]deliverySample {
	b.Helper()
	log, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		b.Fatal(err)
	}
	result := make(map[string][]deliverySample)
	for _, line := range strings.Split(string(log), "\n") {
		raw, ok := strings.CutPrefix(line, "weaver-provider-delivery ")
		if !ok {
			continue
		}
		fields := strings.Fields(raw)
		if len(fields) < 2 || result[fields[0]] != nil {
			b.Fatalf("invalid delivery observation: %q", raw)
		}
		rows := make([]deliverySample, 0, len(fields)-1)
		for _, field := range fields[1:] {
			parts := strings.Split(field, ":")
			if len(parts) != 6 {
				b.Fatalf("invalid delivery fields: %q", field)
			}
			var n [6]uint64
			for i, part := range parts {
				value, err := strconv.ParseUint(part, 10, 64)
				if err != nil || value > uint64(1<<63-1) {
					b.Fatalf("invalid delivery number: %q", field)
				}
				n[i] = value
			}
			if n[1] == 0 || n[2] < n[1] || n[0] != uint64(len(rows)) {
				b.Fatalf("invalid delivery order: %q", field)
			}
			rows = append(rows, deliverySample{n[0], int64(n[1]), int64(n[2]), time.Duration(n[3]), time.Duration(n[4]), n[5]})
		}
		result[fields[0]] = rows
	}
	return result
}

func reportDeliveryJoin(b *testing.B, arm *providerTailArm, label string) {
	b.Helper()
	samples := readDeliverySamples(b, arm.fixture)
	var wait, turn, ackToTonic, tonicToGo []time.Duration
	var unchanged, requalified []time.Duration
	var refreshed uint64
	for _, stream := range arm.streams {
		rows := samples[stream.family]
		if len(rows) != stream.transport.frames {
			b.Fatalf("%s incomplete receiver observation for %s", label, stream.family)
		}
		for _, row := range rows {
			received, ok := stream.transport.received[row.first]
			if !ok || received < row.accepted {
				b.Fatalf("invalid receiver clock for %s", stream.family)
			}
			wait = append(wait, row.wait)
			turn = append(turn, row.turn)
			ack := time.Duration(row.accepted - row.acknowledged)
			ackToTonic = append(ackToTonic, ack)
			if row.refresh == 0 {
				unchanged = append(unchanged, ack)
			} else {
				requalified = append(requalified, ack)
			}
			tonicToGo = append(tonicToGo, time.Duration(received-row.accepted))
			refreshed += row.refresh
		}
	}
	b.ReportMetric(tailMillis(wait, 99)*1000, label+"-final-lock-wait-p99-us/frame")
	b.ReportMetric(tailMillis(turn, 99)*1000, label+"-final-turn-p99-us/frame")
	b.ReportMetric(tailMillis(ackToTonic, 99)*1000, label+"-ack-to-tonic-p99-us/frame")
	b.ReportMetric(tailMillis(tonicToGo, 99)*1000, label+"-tonic-to-go-p99-us/frame")
	b.ReportMetric(float64(refreshed)/float64(len(turn)), label+"-rechecks/frame")
	b.ReportMetric(float64(len(requalified)), label+"-requalified-frames")
	for _, bin := range []struct {
		name string
		rows []time.Duration
	}{{"no-requalification", unchanged}, {"requalified", requalified}} {
		if len(bin.rows) > 0 {
			b.ReportMetric(tailMillis(bin.rows, 99)*1000, label+"-"+bin.name+"-ack-to-tonic-p99-us/frame")
		}
	}
}
