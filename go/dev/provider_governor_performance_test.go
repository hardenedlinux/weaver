// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && schemeintegration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type governorTrial struct {
	arm          string
	replay       bool
	retained     bool
	innerJoinCut string
	outerJoinCut string
}

func (trial governorTrial) offerReplay(ctx context.Context, f *fixture, producer string) <-chan error {
	if !trial.replay {
		return nil
	}
	offered := make(chan struct{})
	result := make(chan error, 1)
	go func() {
		close(offered)
		_, err := f.admin.CompileSource(ctx, producer)
		result <- err
	}()
	<-offered
	return result
}

func (trial *governorTrial) finish(t *testing.T, f *fixture, c *controlProcess) {
	t.Helper()
	c.stop(t)
	start := time.Now()
	type shutdownObservation struct {
		stage string
		at    time.Time
	}
	var observations [3]shutdownObservation
	count := 0
	f.stopObserved(t, func(stage string, at time.Time) {
		observations[count] = shutdownObservation{stage, at}
		count++
	})
	drain := time.Since(start)
	for _, observation := range observations[:count] {
		t.Logf("governor shutdown stage=%s wall_ns=%d elapsed_ns=%d",
			observation.stage, observation.at.UnixNano(), observation.at.Sub(start).Nanoseconds())
	}
	log, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
	if err != nil {
		t.Fatal(err)
	}
	type boundary struct {
		mono, wall uint64
	}
	commits := make(map[string]boundary)
	var begin, end uint64
	mode := "fresh"
	if trial.retained {
		mode = "retained"
	}
	var modeObserved bool
	var derivations int
	var ownerDecisions int
	var innerJoinCut, outerJoinCut string
	readyDigest := func(result string) string {
		digest := sha256.Sum256([]byte(result))
		return hex.EncodeToString(digest[:])
	}
	innerReady := readyDigest(`["inner-finish"]`)
	outerReady := readyDigest(`["finish"]`)
	matchJoin := func(target *string, cut, predecessor, successor string) {
		if commits["release/"+predecessor].wall == 0 || commits["reserve/"+successor].wall != 0 {
			return
		}
		if *target != "" && *target != cut {
			t.Fatal("join had multiple distinct Governor inputs", successor, *target, cut)
		}
		*target = cut
	}
	readDigest := func(field, prefix string) string {
		digest, found := strings.CutPrefix(field, prefix)
		decoded, err := hex.DecodeString(digest)
		if !found || err != nil || len(decoded) != sha256.Size {
			t.Fatal("invalid Governor decision digest", field)
		}
		return digest
	}
	parse := func(field string) uint64 {
		value, err := strconv.ParseUint(field, 10, 64)
		if err != nil {
			t.Fatal("malformed Governor trace", field, err)
		}
		return value
	}
	lines := strings.Split(string(log), "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, "weaver shutdown stage=") ||
			strings.HasPrefix(line, "weaver scheme phase=") ||
			strings.HasPrefix(line, "weaver-governor-") {
			t.Log(line)
		}
	}
	if t.Failed() {
		t.Logf("governor trial arm=%s replay=%t status=failed drain_ns=%d", trial.arm, trial.replay, drain.Nanoseconds())
		return
	}
	for _, line := range lines {
		if !strings.HasPrefix(line, "weaver-governor-") {
			continue
		}
		fields := strings.Fields(line)
		switch fields[0] {
		case "weaver-governor-mode":
			if len(fields) != 2 || fields[1] != mode {
				t.Fatal("unexpected Scheme Governor mode", line)
			}
			modeObserved = true
		case "weaver-governor-ascent":
			expected := "fresh"
			if trial.retained {
				// The scenario keeps its topology fixed while release facts change.
				expected = "open"
				if derivations > 0 {
					expected = "replace"
				}
			}
			if len(fields) != 4 || fields[3] != "mode="+expected {
				t.Fatalf("Governor decision %d expected %s: %s", derivations+1, expected, line)
			}
			derivations++
		case "weaver-governor-owner":
			if len(fields) != 6 || fields[3] != "ok=true" {
				t.Fatal("invalid or failed Governor owner decision", line)
			}
			ownerDecisions++
			cut := readDigest(fields[4], "cut_sha256=")
			ready := readDigest(fields[5], "ready_sha256=")
			switch ready {
			case innerReady:
				matchJoin(&innerJoinCut, cut, "fork-b", "inner-finish")
			case outerReady:
				matchJoin(&outerJoinCut, cut, "inner-finish", "finish")
			}
		case "weaver-governor-commit":
			if len(fields) != 7 {
				t.Fatal("invalid commit trace", line)
			}
			key := fields[1] + "/" + fields[3]
			if _, duplicate := commits[key]; duplicate {
				t.Fatal("duplicate committed boundary", key)
			}
			commits[key] = boundary{mono: parse(fields[4]), wall: parse(fields[5])}
		case "weaver-governor-compile":
			if len(fields) != 3 {
				t.Fatal("invalid compile trace", line)
			}
			at := parse(fields[2])
			if at == 0 {
				t.Fatal("zero native compile timestamp", line)
			}
			switch fields[1] {
			case "begin":
				if begin != 0 {
					t.Fatal("duplicate native compile entry", line)
				}
				begin = at
			case "end":
				if end != 0 {
					t.Fatal("duplicate native compile exit", line)
				}
				end = at
			default:
				t.Fatal("unknown native compile boundary", line)
			}
		}
	}
	if !modeObserved {
		t.Fatal("missing Scheme Governor mode observation")
	}
	if derivations < 2 || ownerDecisions != derivations || innerJoinCut == "" || outerJoinCut == "" {
		t.Fatalf("incomplete Governor decision trace: ASCENT=%d owner=%d inner cut=%q outer cut=%q", derivations, ownerDecisions, innerJoinCut, outerJoinCut)
	}
	a, b := commits["release/fork-a"], commits["release/fork-b"]
	innerRelease, innerReserve := commits["release/inner-finish"], commits["reserve/inner-finish"]
	outer := commits["reserve/finish"]
	if a.wall == 0 || b.mono <= a.mono || innerReserve.mono <= b.mono ||
		innerRelease.mono <= innerReserve.mono || outer.mono <= innerRelease.mono {
		t.Fatal("missing or out-of-order fork and join evidence", commits)
	}
	overlap := a.wall < begin && begin < b.wall && b.wall < end
	if begin == 0 || end <= begin || end >= a.wall {
		t.Fatalf("unexpected native compile entry: replay=%t fork-a=%d begin=%d fork-b=%d end=%d", trial.replay, a.wall, begin, b.wall, end)
	}
	trial.innerJoinCut = innerJoinCut
	trial.outerJoinCut = outerJoinCut
	t.Logf("governor inner-join cut_sha256=%s ready_sha256=%s", innerJoinCut, innerReady)
	t.Logf("governor outer-join cut_sha256=%s ready_sha256=%s", outerJoinCut, outerReady)
	t.Logf("governor trial arm=%s replay=%t status=complete inner_ns=%d outer_ns=%d drain_ns=%d overlap=%t",
		trial.arm, trial.replay, innerReserve.mono-b.mono, outer.mono-innerRelease.mono, drain.Nanoseconds(), overlap)
}
