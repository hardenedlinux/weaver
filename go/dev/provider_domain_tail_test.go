// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"bufio"
	"cmp"
	"fmt"
	"io"
	"math/bits"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const pressureChild = "WEAVER_TEST_CPU_PRESSURE_CHILD"

// The child exits on stdin EOF, so a benchmark never leaves burners running.
func TestProviderCPUPressureWorker(t *testing.T) {
	if os.Getenv(pressureChild) != "1" {
		t.Skip("benchmark child")
	}
	workers, err := strconv.Atoi(os.Getenv("WEAVER_TEST_CPU_PRESSURE_WORKERS"))
	if err != nil || workers < 1 || workers > runtime.NumCPU() {
		t.Fatal("invalid CPU pressure worker count")
	}
	runtime.GOMAXPROCS(workers + 1)
	stop := make(chan struct{})
	ready, done := sync.WaitGroup{}, sync.WaitGroup{}
	ready.Add(workers)
	done.Add(workers)
	values := make([]uint64, workers)
	for i := range workers {
		go func() {
			defer done.Done()
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
			value := uint64(i)
			ready.Done()
			for {
				for range 4096 {
					value = bits.RotateLeft64(value+0x9e3779b97f4a7c15, 13)
				}
				select {
				case <-stop:
					values[i] = value
					return
				default:
				}
			}
		}()
	}
	ready.Wait()
	fmt.Println("pressure-ready")
	_, err = io.Copy(io.Discard, os.Stdin)
	close(stop)
	done.Wait()
	runtime.KeepAlive(values)
	if err != nil {
		t.Fatal(err)
	}
}

func startProviderPressure(b *testing.B, workers int) func() (time.Duration, time.Duration) {
	b.Helper()
	binary, err := os.Executable()
	if err != nil {
		b.Fatal(err)
	}
	cmd := exec.CommandContext(b.Context(), binary, "-test.run=^TestProviderCPUPressureWorker$")
	cmd.Env = append(os.Environ(), pressureChild+"=1", fmt.Sprintf("WEAVER_TEST_CPU_PRESSURE_WORKERS=%d", workers))
	cmd.Stderr = os.Stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		b.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		b.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		b.Fatal(err)
	}
	started := time.Now()
	var once sync.Once
	var cpu, wall time.Duration
	var waitErr error
	stop := func() (time.Duration, time.Duration) {
		once.Do(func() {
			_ = in.Close()
			waitErr = cmd.Wait()
			wall = time.Since(started)
			if waitErr == nil {
				cpu = cmd.ProcessState.UserTime() + cmd.ProcessState.SystemTime()
			}
		})
		return cpu, wall
	}
	b.Cleanup(func() { stop() })
	ready := make(chan string, 1)
	go func() {
		reader := bufio.NewReader(out)
		line, _ := reader.ReadString('\n')
		ready <- strings.TrimSpace(line)
		_, _ = io.Copy(io.Discard, reader)
	}()
	select {
	case line := <-ready:
		if line != "pressure-ready" {
			b.Fatalf("CPU pressure startup: %q", line)
		}
	case <-time.After(5 * time.Second):
		b.Fatal("CPU pressure startup timed out")
	}
	return func() (time.Duration, time.Duration) {
		cpu, wall := stop()
		if waitErr != nil {
			b.Fatalf("CPU pressure shutdown: %v", waitErr)
		}
		return cpu, wall
	}
}

// This host timer probe measures wake-up lateness from the Go driver.
// It does not assign native waits or Rust thread preemption to a cause.
func startProviderTimerProbe(b *testing.B) func() []time.Duration {
	stop := make(chan struct{})
	samples := make(chan []time.Duration, 1)
	go func() {
		var result []time.Duration
		const period = 2 * time.Millisecond
		due := time.Now().Add(period)
		timer := time.NewTimer(period)
		defer timer.Stop()
		for {
			select {
			case <-timer.C:
				result = append(result, max(0, time.Since(due)))
				due = time.Now().Add(period)
				timer.Reset(period)
			case <-stop:
				samples <- result
				return
			}
		}
	}()
	var once sync.Once
	var collected []time.Duration
	finish := func() []time.Duration {
		once.Do(func() {
			close(stop)
			collected = <-samples
		})
		return collected
	}
	b.Cleanup(func() { finish() })
	return finish
}

type providerTailObservation [6]time.Duration

var providerTailPhases = [...]string{"worker-queue", "worker", "domain-wait", "domain-hold", "commit", "domain-read"}

func providerTailObservations(b *testing.B, f *fixture) map[string]providerTailObservation {
	b.Helper()
	log, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		b.Fatal(err)
	}
	result := make(map[string]providerTailObservation)
	for _, line := range strings.Split(string(log), "\n") {
		row, ok := strings.CutPrefix(line, "weaver-provider-tail ")
		if !ok {
			continue
		}
		fields := strings.Fields(row)
		if len(fields) != 1+len(providerTailPhases) {
			b.Fatalf("invalid provider phase observation: %q", row)
		}
		var sample providerTailObservation
		for i, raw := range fields[1:] {
			nanos, err := strconv.ParseInt(raw, 10, 64)
			if err != nil || nanos < 0 {
				b.Fatalf("invalid provider phase duration: %q", raw)
			}
			sample[i] = time.Duration(nanos)
		}
		if _, exists := result[fields[0]]; exists {
			b.Fatalf("duplicate provider phase observation for %s", fields[0])
		}
		result[fields[0]] = sample
	}
	return result
}

type providerTailArm struct {
	fixture *fixture
	streams []domainStreamSample
	wall    time.Duration
}

func BenchmarkProviderSharedLongTail(b *testing.B) {
	b.StopTimer()
	const ranges, parallel, samples, blockWaves = 13, 4, 128, 8
	image := wifImage(b, true)
	var arms [2][2]providerTailArm
	for pressure := range arms {
		for algorithm := range arms[pressure] {
			env := []string{"WEAVER_STORAGE_JOURNAL=mvcc", "WEAVER_TEST_PROVIDER_TAIL=1",
				"WEAVER_TEST_CACHE_CURRENTNESS_PLANS=0", "WEAVER_TEST_LOCKED_PUBLICATION_REVIEW=0",
				"WEAVER_TEST_LOCKED_ORIGINAL_EVIDENCE=0", "WEAVER_TEST_FRESH_PROVIDER_DOMAIN_PLAN=0",
				fmt.Sprintf("WEAVER_TEST_SEPARATE_RELEASE_READS=%d", 1-algorithm)}
			arms[pressure][algorithm].fixture = newDomainBenchmarkFixture(b, image, ranges, env)
		}
	}
	workers := max(1, runtime.NumCPU()/2)
	var probe [2][]time.Duration
	var pressureCPU, pressureWall time.Duration
	b.StartTimer()
	for block := range b.N * samples / (parallel * blockWaves) {
		for _, pressure := range []int{block % 2, 1 - block%2} {
			var stopPressure func() (time.Duration, time.Duration)
			if pressure != 0 {
				stopPressure = startProviderPressure(b, workers)
			}
			stopProbe := startProviderTimerProbe(b)
			for w := range blockWaves {
				wave := block*blockWaves + w
				for _, algorithm := range []int{wave % 2, 1 - wave%2} {
					arm := &arms[pressure][algorithm]
					plans := registerDomainProgramWave(b, arm.fixture, wave, parallel, true)
					streams, wall := measureDomainProgramWave(b, arm.fixture, plans, ranges, true)
					arm.streams = append(arm.streams, streams...)
					arm.wall += wall
				}
			}
			probe[pressure] = append(probe[pressure], stopProbe()...)
			if stopPressure != nil {
				cpu, wall := stopPressure()
				pressureCPU += cpu
				pressureWall += wall
			}
		}
	}
	b.StopTimer()
	b.ReportMetric(0, "ns/op")
	b.ReportMetric(float64(workers), "pressure-workers")
	b.ReportMetric(pressureCPU.Seconds()/pressureWall.Seconds(), "pressure-cpu-equivalents")
	for pressure, load := range []string{"idle", "loaded"} {
		if len(probe[pressure]) == 0 {
			b.Fatal("missing host timer samples")
		}
		b.ReportMetric(tailMillis(probe[pressure], 99), load+"-host-timer-p99-ms")
		for algorithm, name := range []string{"separate", "joined"} {
			reportProviderTailArm(b, &arms[pressure][algorithm], load+"-"+name)
		}
	}
}

func reportProviderTailArm(b *testing.B, arm *providerTailArm, name string) {
	b.Helper()
	total := len(arm.streams)
	if arm.fixture.primary.Load() != int64(total) || arm.fixture.backup.Load() != 0 || arm.fixture.denied.Load() != 0 {
		b.Fatalf("%s had substituted or duplicate sends", name)
	}
	byFamily := providerTailObservations(b, arm.fixture)
	if len(byFamily) != total {
		b.Fatalf("%s phase observations: got %d want %d", name, len(byFamily), total)
	}
	slices.SortFunc(arm.streams, func(a, b domainStreamSample) int { return cmp.Compare(a.latency, b.latency) })
	p99 := arm.streams[tailRank(total, 99)]
	var domainSum time.Duration
	var phases [len(providerTailPhases)][]time.Duration
	for _, stream := range arm.streams {
		row, ok := byFamily[stream.family]
		if !ok {
			b.Fatalf("%s missing timing for %s", name, stream.family)
		}
		domainSum += row[5]
		for i, value := range row {
			phases[i] = append(phases[i], value)
		}
	}
	for i, label := range providerTailPhases {
		b.ReportMetric(tailMillis(phases[i], 99), name+"-"+label+"-p99-ms")
		b.ReportMetric(millis(byFamily[p99.family][i]), name+"-"+label+"-at-stream-p99-ms")
	}
	b.ReportMetric(millis(domainSum)/float64(total), name+"-domain-read-mean-ms")
	b.ReportMetric(millis(arm.streams[tailRank(total, 95)].latency), name+"-stream-p95-ms")
	b.ReportMetric(millis(p99.latency), name+"-stream-p99-ms")
	b.ReportMetric(float64(total)/arm.wall.Seconds(), name+"-complete/s")
	b.ReportMetric(float64(total), name+"-completed")
	arm.fixture.stop(b)
}

func tailRank(n, percentile int) int { return (percentile*n+99)/100 - 1 }

func tailMillis(samples []time.Duration, percentile int) float64 {
	slices.Sort(samples)
	return millis(samples[tailRank(len(samples), percentile)])
}

func millis(value time.Duration) float64 { return float64(value) / float64(time.Millisecond) }
