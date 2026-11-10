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
	arm            string
	replay         bool
	retained       bool
	fullCut        bool
	namedResult    bool
	preopen        bool
	changedSources bool
	packedFacts    bool
	innerJoinCut   string
	outerJoinCut   string
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
	var transports, resultModes, factModes, relationModes, roundtrips, resolutions int
	var lastRoundtrip uint64
	var reducedSources bool
	var ascentMode string
	var hasGovernorFFI bool
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
	preparing, prepared, preparedRules := false, false, false
	for _, line := range lines {
		if !strings.HasPrefix(line, "weaver-governor-") {
			continue
		}
		fields := strings.Fields(line)
		if fields[0] == "weaver-governor-preopen" {
			switch {
			case len(fields) == 2 && fields[1] == "begin" && trial.preopen && !preparing && !prepared && derivations == 0:
				preparing = true
			case len(fields) == 4 && fields[1] == "end" && fields[2] == "ok=true" && preparing && preparedRules:
				preparing, prepared = false, true
			default:
				t.Fatal("invalid Governor preparation trace", line)
			}
			continue
		}
		if preparing {
			if fields[0] == "weaver-governor-ascent" {
				if preparedRules || len(fields) != 4 || fields[3] != "mode=open" {
					t.Fatal("preparation did not open exactly one ASCENT session", line)
				}
				preparedRules = true
			}
			continue
		}
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
				if derivations > 0 || prepared {
					expected = "replace"
				}
			}
			if trial.changedSources && expected == "replace" && len(fields) == 4 && fields[3] == "mode=reuse" {
				expected = "reuse"
			}
			if len(fields) != 4 || fields[3] != "mode="+expected {
				t.Fatalf("Governor decision %d expected %s: %s", derivations+1, expected, line)
			}
			ascentMode = expected
			derivations++
		case "weaver-governor-relations":
			if len(fields) != 2 || !strings.HasPrefix(fields[1], "count=") {
				t.Fatal("invalid Governor source count", line)
			}
			count := parse(strings.TrimPrefix(fields[1], "count="))
			if relationModes >= derivations || count > 7 ||
				(!trial.changedSources && count != 7) ||
				(ascentMode == "reuse" && count != 0) ||
				(ascentMode != "reuse" && count == 0) {
				t.Fatal("unexpected Governor source replacement", line)
			}
			reducedSources = reducedSources || count < 7
			relationModes++
		case "weaver-governor-roundtrip":
			if len(fields) != 8 || roundtrips >= derivations {
				t.Fatal("unmatched Governor roundtrip", line)
			}
			var sum uint64
			for i, key := range []string{"capacity_ns=", "submit_ns=", "wait_ns=", "derive_ns=", "trace_ns=", "response_ns="} {
				if !strings.HasPrefix(fields[i+1], key) {
					t.Fatal("invalid Governor roundtrip phase", line)
				}
				sum += parse(strings.TrimPrefix(fields[i+1], key))
			}
			lastRoundtrip = parse(strings.TrimPrefix(fields[7], "total_ns="))
			if sum != lastRoundtrip || lastRoundtrip == 0 {
				t.Fatal("Governor roundtrip phases do not cover the call", line)
			}
			roundtrips++
		case "weaver-governor-resolve":
			if len(fields) != 5 || resolutions >= roundtrips {
				t.Fatal("unmatched Governor resolution", line)
			}
			elapsed := parse(strings.TrimPrefix(fields[1], "elapsed_ns="))
			prepare := parse(strings.TrimPrefix(fields[2], "prepare_ns="))
			roundtrip := parse(strings.TrimPrefix(fields[3], "roundtrip_ns="))
			validate := parse(strings.TrimPrefix(fields[4], "validate_ns="))
			if elapsed != prepare+roundtrip+validate || roundtrip < lastRoundtrip {
				t.Fatal("Governor resolution phases do not cover the call", line)
			}
			resolutions++
		case "weaver-governor-transport":
			expected := "full"
			if trial.retained && !trial.fullCut {
				expected = "compact"
				if transports == 0 && !prepared {
					expected = "bind"
				}
			}
			if len(fields) != 2 || fields[1] != "mode="+expected {
				t.Fatalf("Governor transport %d expected %s: %s", transports+1, expected, line)
			}
			transports++
		case "weaver-governor-result":
			expected := "named"
			if trial.retained && !trial.fullCut && !trial.namedResult {
				expected = "indexed"
			}
			if len(fields) != 2 || fields[1] != "mode="+expected {
				t.Fatalf("Governor result %d expected %s: %s", resultModes+1, expected, line)
			}
			resultModes++
		case "weaver-governor-facts":
			expected := "named"
			if trial.packedFacts && (prepared || factModes > 0) {
				expected = "packed"
			}
			if len(fields) != 2 || fields[1] != "mode="+expected {
				t.Fatalf("Governor facts %d expected %s: %s", factModes+1, expected, line)
			}
			factModes++
		case "weaver-governor-ffi":
			if hasGovernorFFI || len(fields) != 4 {
				t.Fatal("unmatched Governor FFI observation", line)
			}
			hasGovernorFFI = true
		case "weaver-governor-owner":
			if len(fields) != 6 || fields[3] != "ok=true" {
				t.Fatal("invalid or failed Governor owner decision", line)
			}
			// Fact impact uses the same owner but does not enter Governor FFI.
			if !hasGovernorFFI {
				continue
			}
			hasGovernorFFI = false
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
				t.Fatal("zero Scheme compile timestamp", line)
			}
			switch fields[1] {
			case "begin":
				if begin != 0 {
					t.Fatal("duplicate Scheme compile entry", line)
				}
				begin = at
			case "end":
				if end != 0 {
					t.Fatal("duplicate Scheme compile exit", line)
				}
				end = at
			default:
				t.Fatal("unknown Scheme compile boundary", line)
			}
		}
	}
	if !modeObserved {
		t.Fatal("missing Scheme Governor mode observation")
	}
	if preparing || prepared != trial.preopen || hasGovernorFFI || derivations < 2 || ownerDecisions != derivations || transports != derivations || resultModes != derivations || factModes != derivations || relationModes != derivations || roundtrips < 2 || resolutions < 2 || resolutions > roundtrips || roundtrips > derivations || (trial.changedSources && !reducedSources) || innerJoinCut == "" || outerJoinCut == "" {
		t.Fatalf("incomplete Governor decision trace: ASCENT=%d owner=%d inner cut=%q outer cut=%q", derivations, ownerDecisions, innerJoinCut, outerJoinCut)
	}
	t.Logf("governor observations derived=%d replied=%d resolved=%d", derivations, roundtrips, resolutions)
	a, b := commits["release/fork-a"], commits["release/fork-b"]
	innerRelease, innerReserve := commits["release/inner-finish"], commits["reserve/inner-finish"]
	outer := commits["reserve/finish"]
	if a.wall == 0 || b.mono <= a.mono || innerReserve.mono <= b.mono ||
		innerRelease.mono <= innerReserve.mono || outer.mono <= innerRelease.mono {
		t.Fatal("missing or out-of-order fork and join evidence", commits)
	}
	overlap := a.wall < begin && begin < b.wall && b.wall < end
	if begin == 0 || end <= begin || end >= a.wall {
		t.Fatalf("unexpected Scheme compile entry: replay=%t fork-a=%d begin=%d fork-b=%d end=%d", trial.replay, a.wall, begin, b.wall, end)
	}
	trial.innerJoinCut = innerJoinCut
	trial.outerJoinCut = outerJoinCut
	t.Logf("governor inner-join cut_sha256=%s ready_sha256=%s", innerJoinCut, innerReady)
	t.Logf("governor outer-join cut_sha256=%s ready_sha256=%s", outerJoinCut, outerReady)
	t.Logf("governor trial arm=%s replay=%t status=complete inner_ns=%d outer_ns=%d drain_ns=%d overlap=%t",
		trial.arm, trial.replay, innerReserve.mono-b.mono, outer.mono-innerRelease.mono, drain.Nanoseconds(), overlap)
}
