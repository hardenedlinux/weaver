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

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
)

func BenchmarkProviderScheduledEncoding(b *testing.B) {
	image := wifImage(b, true)
	for _, shared := range []bool{true, false} {
		for _, loaded := range []bool{false, true} {
			b.Run(fmt.Sprintf("shared=%t/pressure=%t", shared, loaded), func(b *testing.B) {
				benchmarkProviderScheduledEncoding(b, image, shared, loaded)
			})
		}
	}
}

func benchmarkProviderScheduledEncoding(b *testing.B, image string, shared, loaded bool) {
	b.Helper()
	b.StopTimer()
	const events, parallel, streams = 13, 4, 128
	modes := [...]struct {
		label    string
		encoding pb.Encoding
		rows     uint32
	}{
		{"protobuf-1", pb.Encoding_PROTOBUF, 1},
		{"arrow-1", pb.Encoding_ARROW_IPC, 1},
		{"arrow-4", pb.Encoding_ARROW_IPC, 4},
	}
	var arms [len(modes)]providerTailArm
	for i := range modes {
		arms[i].fixture = newDomainBenchmarkFixture(b, image, events, []string{
			"WEAVER_STORAGE_JOURNAL=mvcc",
			"WEAVER_TEST_PROVIDER_TAIL=1",
			"WEAVER_TEST_PROVIDER_SCOPE_TRACE=1",
		})
	}
	var stopPressure func() (time.Duration, time.Duration)
	if loaded {
		stopPressure = startProviderPressure(b, max(1, runtime.NumCPU()/2))
	}
	b.StartTimer()
	for wave := range b.N * streams / parallel {
		for offset := range modes {
			i := (wave + offset) % len(modes)
			arm, mode := &arms[i], modes[i]
			plans := registerDomainProgramWave(b, arm.fixture, wave, parallel, shared)
			samples, wall := measureDomainEncodingWave(b, arm.fixture, plans, events, shared, mode.encoding, mode.rows)
			arm.streams = append(arm.streams, samples...)
			arm.wall += wall
		}
	}
	b.StopTimer()
	if stopPressure != nil {
		cpu, wall := stopPressure()
		b.ReportMetric(cpu.Seconds()/wall.Seconds(), "pressure-cpu-equivalents")
	}
	b.ReportMetric(0, "ns/op")
	for i, mode := range modes {
		arm := &arms[i]
		reportProviderTailArm(b, arm, mode.label)
		ranges := (events + int(mode.rows) - 1) / int(mode.rows)
		if shared {
			reportProviderRangeScopes(b, arm, mode.label, ranges, parallel)
		}
		reportScheduledEncoding(b, arm, mode.label, ranges, shared)
		arm.fixture.stop(b)
	}
}

func reportScheduledEncoding(b *testing.B, arm *providerTailArm, label string, ranges int, shared bool) {
	b.Helper()
	encodes := providerEncodingObservations(b, arm.fixture)
	handoffs := providerHandoffs(b, arm.fixture)
	scopes := readRangeScopes(b, arm.fixture)
	waves := make(map[string][]rangeScopeSample)
	var frames, payload int
	var receives, decodes, encodesByStream, queueToRecv, scopeWaits []time.Duration
	for _, stream := range arm.streams {
		encode, ok := encodes[stream.family]
		if !ok || len(scopes[stream.family]) != 5+2*ranges {
			b.Fatalf("%s missing scopes or codec timing for %s", label, stream.family)
		}
		for _, scope := range scopes[stream.family] {
			scopeWaits = append(scopeWaits, scope.wait)
		}
		sent := handoffs[stream.family]
		if len(sent) != stream.transport.frames || len(stream.transport.received) != len(sent) {
			b.Fatalf("%s incomplete handoff observation for %s", label, stream.family)
		}
		for sequence, before := range sent {
			after, ok := stream.transport.received[sequence]
			if !ok || before > after {
				b.Fatalf("%s invalid same-host clock observation for %s sequence %d", label, stream.family, sequence)
			}
			queueToRecv = append(queueToRecv, time.Duration(after-before))
		}
		frames += stream.transport.frames
		payload += stream.transport.messageBytes
		receives = append(receives, stream.transport.recv)
		decodes = append(decodes, stream.transport.decode)
		encodesByStream = append(encodesByStream, encode)
		if shared {
			wave, _, _ := strings.Cut(stream.family[len("domain-"):], "-")
			waves[wave] = append(waves[wave], scopes[stream.family]...)
		}
	}
	for _, wave := range waves {
		for _, scope := range wave {
			if rangeScopeOvertakes(wave, scope) != 0 {
				b.Fatalf("%s conflicting ticket overtook %s arrival %d", label, scope.family, scope.arrival)
			}
		}
	}
	n := float64(len(arm.streams))
	b.ReportMetric(float64(frames)/n, label+"-frames/stream")
	b.ReportMetric(float64(payload)/n, label+"-protobuf-bytes/stream")
	b.ReportMetric(tailMillis(scopeWaits, 99), label+"-ticket-wait-p99-ms/scope")
	b.ReportMetric(tailMillis(queueToRecv, 99), label+"-rust-queue-to-go-p99-ms/frame")
	b.ReportMetric(tailMillis(receives, 99), label+"-grpc-recv-wait-p99-ms")
	b.ReportMetric(tailMillis(decodes, 99), label+"-go-decode-p99-ms")
	b.ReportMetric(tailMillis(encodesByStream, 99), label+"-rust-encode-p99-ms")
}

func providerEncodingObservations(b *testing.B, f *fixture) map[string]time.Duration {
	b.Helper()
	log, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		b.Fatal(err)
	}
	encodes := make(map[string]time.Duration)
	for _, line := range strings.Split(string(log), "\n") {
		raw, ok := strings.CutPrefix(line, "weaver-provider-encode ")
		if !ok {
			continue
		}
		family, elapsed, ok := strings.Cut(raw, " ")
		ns, err := strconv.ParseInt(elapsed, 10, 64)
		_, duplicate := encodes[family]
		if !ok || err != nil || duplicate || ns < 0 {
			b.Fatalf("invalid codec observation: %q", raw)
		}
		encodes[family] = time.Duration(ns)
	}
	return encodes
}

func providerHandoffs(b *testing.B, f *fixture) map[string]map[uint64]int64 {
	b.Helper()
	log, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		b.Fatal(err)
	}
	result := make(map[string]map[uint64]int64)
	for _, line := range strings.Split(string(log), "\n") {
		raw, ok := strings.CutPrefix(line, "weaver-provider-handoff ")
		if !ok {
			continue
		}
		fields := strings.Fields(raw)
		if len(fields) < 2 || result[fields[0]] != nil {
			b.Fatalf("invalid handoff observation: %q", raw)
		}
		stamps := make(map[uint64]int64)
		for _, field := range fields[1:] {
			sequence, timestamp, ok := strings.Cut(field, ":")
			seq, seqErr := strconv.ParseUint(sequence, 10, 64)
			nanos, timeErr := strconv.ParseInt(timestamp, 10, 64)
			if !ok || seqErr != nil || timeErr != nil || nanos <= 0 || stamps[seq] != 0 {
				b.Fatalf("invalid handoff timestamp: %q", field)
			}
			stamps[seq] = nanos
		}
		result[fields[0]] = stamps
	}
	return result
}
