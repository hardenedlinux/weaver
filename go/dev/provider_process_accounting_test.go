// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

type controlAccounting struct {
	before         map[int]time.Duration
	driver         runtime.MemStats
	pids           [2][5]int
	heapBefore     [2][4][2]uint64
	heapIdle       [2][2]uint64
	heapEnabled    bool
	profileRoot    string
	rustHeapBefore [2][8]uint64
	rustHeapIdle   [2][8]uint64
	rustStackStart [2]uint64
}

func startControlAccounting(b *testing.B, arms [2]*controlBenchArm) controlAccounting {
	b.Helper()
	var measurement controlAccounting
	for i, arm := range arms {
		measurement.pids[i][0] = arm.f.child.Process.Pid
		for j, owner := range arm.control {
			measurement.pids[i][j+1] = owner.child.Process.Pid
		}
		if slices.Contains(arm.f.env, "WEAVER_TEST_RUST_HEAP_ARM=1") {
			idle := readRustHeapCounters(b, arm.f)
			measurement.rustHeapBefore[i] = readRustHeapCounters(b, arm.f)
			if os.Getenv("WEAVER_TEST_RUST_HEAP_STACK_ROOT") != "" {
				measurement.rustStackStart[i] = rustAllocationStackCursor(b, arm.f)
			}
			for metric, current := range measurement.rustHeapBefore[i] {
				if current < idle[metric] {
					b.Fatal("Rust heap counter moved backwards")
				}
				measurement.rustHeapIdle[i][metric] = current - idle[metric]
			}
		}
	}
	measurement.before = measurement.cpuTimes(b)
	runtime.ReadMemStats(&measurement.driver)
	measurement.heapEnabled = os.Getenv("WEAVER_TEST_CONTROL_HEAP") == "1"
	measurement.profileRoot = os.Getenv("WEAVER_TEST_CONTROL_PROFILE_ROOT")
	if measurement.profileRoot != "" && (!measurement.heapEnabled || !filepath.IsAbs(measurement.profileRoot)) {
		b.Fatal("control heap profiles require the heap observer and an absolute evidence directory")
	}
	if measurement.heapEnabled {
		for i, arm := range arms {
			for j, owner := range arm.control {
				if measurement.profileRoot != "" {
					controlHeapCommand(b, owner, 2, 10*time.Second)
				}
				idle := readControlHeap(b, owner)
				measurement.heapBefore[i][j] = readControlHeap(b, owner)
				for metric, after := range measurement.heapBefore[i][j] {
					if after < idle[metric] {
						b.Fatal("control heap counter moved backwards during idle control")
					}
					measurement.heapIdle[i][metric] += after - idle[metric]
				}
			}
		}
	}
	return measurement
}

func (m *controlAccounting) finish(b *testing.B, arms [2]*controlBenchArm, labels [2]string, streams int) {
	b.Helper()
	var driver runtime.MemStats
	runtime.ReadMemStats(&driver)
	after := m.cpuTimes(b)
	cpu := func(pid int) time.Duration {
		before, end := m.before[pid], after[pid]
		if end < before {
			b.Fatalf("process CPU moved backwards for %d", pid)
		}
		return end - before
	}
	if driver.TotalAlloc < m.driver.TotalAlloc || driver.Mallocs < m.driver.Mallocs {
		b.Fatal("benchmark driver allocation counters moved backwards")
	}
	for arm, label := range labels {
		pids := m.pids[arm]
		var goCPU time.Duration
		for _, pid := range pids[1:] {
			goCPU += cpu(pid)
		}
		b.ReportMetric(millis(cpu(pids[0]))/float64(streams), label+"-rust-cpu-ms/stream")
		b.ReportMetric(millis(goCPU)/float64(streams), label+"-go-control-cpu-ms/stream")
		if slices.Contains(arms[arm].f.env, "WEAVER_TEST_RUST_HEAP_ARM=1") {
			after := readRustHeapCounters(b, arms[arm].f)
			if root := os.Getenv("WEAVER_TEST_RUST_HEAP_STACK_ROOT"); root != "" {
				end := rustAllocationStackCursor(b, arms[arm].f)
				start := m.rustStackStart[arm]
				if end <= start || end > 65536 {
					b.Fatalf("invalid Rust allocation stack window %d..%d", start, end)
				}
				data, err := os.ReadFile(filepath.Join(arms[arm].f.directory, "rust-heap.stacks"))
				if err != nil {
					b.Fatal(err)
				}
				dir := filepath.Join(root, b.Name())
				if err := os.MkdirAll(dir, 0700); err != nil {
					b.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(dir, label+".bin"), data[:24+208*end], 0600); err != nil {
					b.Fatal(err)
				}
				b.ReportMetric(float64(start), label+"-stack-window-start")
				b.ReportMetric(float64(end), label+"-stack-window-end")
			}
			for i, name := range []string{"malloc", "calloc", "realloc", "memalign"} {
				for j, unit := range []string{"calls", "bytes"} {
					index := 2*i + j
					before := m.rustHeapBefore[arm][index]
					if after[index] < before {
						b.Fatal("Rust heap counter moved backwards")
					}
					b.ReportMetric(float64(after[index]-before)/float64(streams), label+"-"+name+"-"+unit+"/stream")
					b.ReportMetric(float64(m.rustHeapIdle[arm][index]), label+"-"+name+"-idle-"+unit)
				}
			}
		}
		if m.heapEnabled {
			var delta [2]uint64
			for j, owner := range arms[arm].control {
				for metric, after := range readControlHeap(b, owner) {
					before := m.heapBefore[arm][j][metric]
					if after < before {
						b.Fatal("control heap counter moved backwards")
					}
					delta[metric] += after - before
				}
				if m.profileRoot != "" {
					controlHeapCommand(b, owner, 3, 10*time.Second)
					dir := filepath.Join(m.profileRoot, b.Name(), label, strconv.Itoa(j))
					if err := os.MkdirAll(dir, 0700); err != nil {
						b.Fatal(err)
					}
					for _, name := range []string{"before.pprof", "after.pprof"} {
						profile, err := os.ReadFile(filepath.Join(owner.directory, name))
						if err != nil {
							b.Fatal(err)
						}
						if err := os.WriteFile(filepath.Join(dir, name), profile, 0600); err != nil {
							b.Fatal(err)
						}
					}
				}
			}
			b.ReportMetric(float64(delta[0])/float64(streams), label+"-go-control-heap-bytes/stream")
			b.ReportMetric(float64(delta[1])/float64(streams), label+"-go-control-heap-allocs/stream")
			b.ReportMetric(float64(m.heapIdle[arm][0]), label+"-go-control-idle-snapshot-bytes")
			b.ReportMetric(float64(m.heapIdle[arm][1]), label+"-go-control-idle-snapshot-allocs")
		}
	}
	total := float64(streams * len(labels))
	b.ReportMetric(millis(cpu(os.Getpid()))/total, "combined-driver-cpu-ms/stream")
	b.ReportMetric(float64(driver.TotalAlloc-m.driver.TotalAlloc)/total, "combined-driver-heap-bytes/stream")
	b.ReportMetric(float64(driver.Mallocs-m.driver.Mallocs)/total, "combined-driver-heap-allocs/stream")
}

func rustAllocationStackCursor(b *testing.B, f *fixture) uint64 {
	b.Helper()
	file, err := os.Open(filepath.Join(f.directory, "rust-heap.stacks"))
	if err != nil {
		b.Fatal(err)
	}
	defer file.Close()
	var header [24]byte
	if _, err := io.ReadFull(file, header[:]); err != nil || binary.LittleEndian.Uint64(header[:]) != 1 {
		b.Fatalf("Rust allocation stack observer did not initialize: %v", err)
	}
	return binary.LittleEndian.Uint64(header[8:])
}

func readRustHeapCounters(b *testing.B, f *fixture) [8]uint64 {
	b.Helper()
	path := filepath.Join(f.directory, "rust-heap.counter")
	var previous []byte
	for range 16 {
		data, err := os.ReadFile(path)
		if err != nil || len(data) != 72 || binary.LittleEndian.Uint64(data) != 1 {
			b.Fatalf("Rust allocator counter did not initialize: %v", err)
		}
		if bytes.Equal(data, previous) {
			var result [8]uint64
			for i := range result {
				result[i] = binary.LittleEndian.Uint64(data[8+8*i:])
			}
			return result
		}
		previous = data
	}
	b.Fatal("Rust allocator counter did not stabilize at the workload boundary")
	return [8]uint64{}
}

func readControlHeap(b *testing.B, owner *controlProcess) [2]uint64 {
	return controlHeapCommand(b, owner, 1, time.Second)
}

func controlHeapCommand(b *testing.B, owner *controlProcess, command byte, timeout time.Duration) [2]uint64 {
	b.Helper()
	if owner.heapInput == nil || owner.heapOutput == nil {
		b.Fatal("Go control heap observer is missing")
	}
	deadline := time.Now().Add(timeout)
	if err := owner.heapInput.SetWriteDeadline(deadline); err != nil {
		b.Fatal(err)
	}
	if err := owner.heapOutput.SetReadDeadline(deadline); err != nil {
		b.Fatal(err)
	}
	if _, err := owner.heapInput.Write([]byte{command}); err != nil {
		b.Fatal(err)
	}
	var response [16]byte
	if _, err := io.ReadFull(owner.heapOutput, response[:]); err != nil {
		b.Fatal(err)
	}
	return [2]uint64{binary.LittleEndian.Uint64(response[:8]), binary.LittleEndian.Uint64(response[8:])}
}

func (m *controlAccounting) cpuTimes(b *testing.B) map[int]time.Duration {
	b.Helper()
	pids := []string{strconv.Itoa(os.Getpid())}
	for _, arm := range m.pids {
		for _, pid := range arm {
			pids = append(pids, strconv.Itoa(pid))
		}
	}
	output, err := exec.Command("ps", "-o", "pid=", "-o", "time=", "-p", strings.Join(pids, ",")).Output()
	if err != nil {
		b.Fatalf("steady process CPU snapshot: %v", err)
	}
	rows := make(map[int]time.Duration)
	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			b.Fatalf("unexpected process CPU row %q", line)
		}
		pid, err := strconv.Atoi(fields[0])
		elapsed, clockErr := processCPUClock(fields[1])
		if err != nil || clockErr != nil {
			b.Fatalf("invalid process CPU row %q", line)
		}
		rows[pid] = elapsed
	}
	for _, text := range pids {
		pid, _ := strconv.Atoi(text)
		if _, ok := rows[pid]; !ok {
			b.Fatalf("process CPU snapshot omitted PID %d", pid)
		}
	}
	return rows
}

// ps emits [[days-]hours:]minutes:seconds, with fractions where supported.
func processCPUClock(clock string) (time.Duration, error) {
	var elapsed time.Duration
	if days, rest, ok := strings.Cut(clock, "-"); ok {
		count, err := strconv.Atoi(days)
		if err != nil || count < 0 {
			return 0, fmt.Errorf("invalid process CPU day %q", days)
		}
		elapsed, clock = time.Duration(count)*24*time.Hour, rest
	}
	parts := strings.Split(clock, ":")
	if len(parts) != 2 && len(parts) != 3 {
		return 0, fmt.Errorf("invalid process CPU clock %q", clock)
	}
	for i, part := range parts {
		unit := [...]string{"h", "m", "s"}[3-len(parts)+i]
		duration, err := time.ParseDuration(part + unit)
		if err != nil || duration < 0 {
			return 0, fmt.Errorf("invalid process CPU clock %q", clock)
		}
		elapsed += duration
	}
	return elapsed, nil
}
