// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package main

import (
	"encoding/binary"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"runtime/metrics"
	"runtime/pprof"
	"testing"
)

func TestMain(m *testing.M) {
	if os.Getenv("WEAVER_TEST_CONTROL_HEAP") != "1" {
		os.Exit(m.Run())
	}
	profileDir := os.Getenv("WEAVER_TEST_CONTROL_PROFILE_DIR")
	if profileDir != "" {
		runtime.MemProfileRate = 1
	}
	go observeHeap(profileDir)
	main()
}

func observeHeap(profileDir string) {
	samples := []metrics.Sample{
		{Name: "/gc/heap/allocs:bytes"},
		{Name: "/gc/heap/allocs:objects"},
	}
	var command [1]byte
	var response [16]byte
	for {
		if _, err := io.ReadFull(os.Stdin, command[:]); err != nil {
			return
		}
		switch command[0] {
		case 1:
		case 2, 3:
			if profileDir == "" {
				return
			}
			name := "before.pprof"
			if command[0] == 3 {
				name = "after.pprof"
			}
			runtime.GC()
			runtime.GC()
			file, err := os.OpenFile(filepath.Join(profileDir, name), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if err != nil {
				return
			}
			writeErr := pprof.Lookup("allocs").WriteTo(file, 0)
			if closeErr := file.Close(); writeErr != nil || closeErr != nil {
				return
			}
		default:
			return
		}
		metrics.Read(samples)
		for i, sample := range samples {
			binary.LittleEndian.PutUint64(response[i*8:], sample.Value.Uint64())
		}
		if _, err := os.Stdout.Write(response[:]); err != nil {
			return
		}
	}
}
