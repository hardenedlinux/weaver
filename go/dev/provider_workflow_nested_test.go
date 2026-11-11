// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && schemeintegration && !windows

package dev

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestProviderControlSessionNestedChoiceAndParallelRecovery(t *testing.T) {
	t.Run("nested-right-after-restart", func(t *testing.T) { checkNestedSession(t, false) })
	t.Run("outer-right-skips-entire-nested-arm", func(t *testing.T) { checkNestedSession(t, true) })
}

func TestProviderControlGovernorPerformance(t *testing.T) {
	cohort := os.Getenv("WEAVER_TEST_GOVERNOR_COHORT")
	switch cohort {
	case "":
		t.Skip("select the preregistered aa, replay, retained, transport, indices, preopen, packed, or changed cohort")
	case "aa", "replay", "retained", "transport", "indices", "preopen", "packed", "changed":
	default:
		t.Fatal("unknown Governor performance cohort", cohort)
	}
	arms := [4]string{"A", "B", "B", "A"}
	parallel, err := strconv.Atoi(flag.Lookup("test.parallel").Value.String())
	if err != nil || parallel != len(arms) {
		t.Fatalf("Governor performance requires -parallel=%d", len(arms))
	}
	var trials [4]governorTrial
	if !t.Run("wave-0", func(t *testing.T) {
		for i, arm := range arms {
			t.Run(fmt.Sprintf("%d-%s", i, arm), func(t *testing.T) {
				t.Parallel()
				trials[i] = governorTrial{
					arm: arm, replay: cohort == "replay" && arm == "B",
					retained:       cohort == "changed" || cohort == "packed" || cohort == "preopen" || cohort == "indices" || cohort == "transport" || (cohort == "retained" && arm == "B"),
					fullCut:        cohort == "transport" && arm == "A",
					namedResult:    cohort == "indices" && arm == "A",
					preopen:        cohort == "changed" || cohort == "packed" || (cohort == "preopen" && arm == "B"),
					packedFacts:    cohort == "changed" || (cohort == "packed" && arm == "B"),
					changedSources: cohort == "changed" && arm == "B",
				}
				runNestedSession(t, false, &trials[i])
			})
		}
	}) {
		return
	}
	for _, trial := range trials {
		if trial.innerJoinCut == "" {
			t.Log("partial Governor wave is diagnostic only")
			return
		}
	}
	for i, trial := range trials {
		if trial.innerJoinCut != trials[0].innerJoinCut {
			t.Fatalf("Governor arm %d-%s observed a different inner-join input: %s, expected %s", i, trial.arm, trial.innerJoinCut, trials[0].innerJoinCut)
		}
		if trial.outerJoinCut != trials[0].outerJoinCut {
			t.Fatalf("Governor arm %d-%s observed a different outer-join input: %s, expected %s", i, trial.arm, trial.outerJoinCut, trials[0].outerJoinCut)
		}
	}
	t.Logf("governor wave matched inner-join cut_sha256=%s trials=%d", trials[0].innerJoinCut, len(trials))
	t.Logf("governor wave matched outer-join cut_sha256=%s trials=%d", trials[0].outerJoinCut, len(trials))
}

func TestProviderControlSourceCancellationDrainsSchemeOwner(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	f.env = append(f.env, "WEAVER_TEST_GOVERNOR_TIMING=1")
	bundle := controlBundle(t, f)
	policy := compiledControlSources(false)
	policy.configure(t, f, bundle)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := f.admin.CompileSource(ctx, policy.producer)
		result <- err
	}()
	path := filepath.Join(f.directory, "server.log")
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		log, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(log), "weaver scheme phase=compile-begin ") {
			break
		}
		select {
		case err := <-result:
			t.Fatalf("source preparation exited before entering Scheme: %v", err)
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-ticker.C:
		}
	}
	f.stop(t)
	if err := <-result; err == nil {
		t.Fatal("cancelled source preparation delivered an artifact")
	}
	log, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	_, active, found := strings.Cut(string(log), "weaver scheme phase=compile-begin ")
	if !found || !strings.Contains(active, "phase=source-preparation-cancelled ") ||
		!strings.Contains(active, "stage=scheme-owner-cleaned") ||
		!strings.Contains(active, "stage=tracked-owners-drained") ||
		strings.Contains(active, "phase=source-captured ") {
		t.Fatalf("cancelled preparation did not unwind and drain: %s", active)
	}
	t.Log("active Scheme source preparation cancelled, VM cleaned, tracked owners naturally drained")
}

func checkNestedSession(t *testing.T, outerRight bool) {
	t.Helper()
	runNestedSession(t, outerRight, nil)
}

func runNestedSession(t *testing.T, outerRight bool, trial *governorTrial) {
	t.Helper()
	arrived := make(chan string, 2)
	aRelease, bRelease := make(chan struct{}), make(chan struct{})
	rootRelease := make(chan struct{})
	var aOnce, bOnce, rootOnce sync.Once
	releaseA := func() { aOnce.Do(func() { close(aRelease) }) }
	releaseB := func() { bOnce.Do(func() { close(bRelease) }) }
	releaseRoot := func() { rootOnce.Do(func() { close(rootRelease) }) }
	defer releaseA()
	defer releaseB()
	defer releaseRoot()
	f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
			return
		}
		content := func(node string) bool { return strings.Contains(string(body), `"content":"`+node+`"`) }
		if content("hello") || content("gate") {
			route := "right"
			if content("hello") && !outerRight {
				route = "left"
			}
			w.Header().Set("Content-Type", "text/event-stream")
			emitChunk(w, `{"route":"`+route+`"}`, false)
			if outerRight && content("hello") {
				select {
				case <-rootRelease:
				case <-r.Context().Done():
					return
				}
			}
			emitChunk(w, "", true)
			fmt.Fprint(w, "data: [DONE]\n\n")
			return
		}
		for node, release := range map[string]chan struct{}{"fork-a": aRelease, "fork-b": bRelease} {
			if content(node) {
				select {
				case arrived <- node:
				default:
					t.Error("duplicate parallel dispatch")
				}
				select {
				case <-release:
				case <-r.Context().Done():
					return
				}
				break
			}
		}
		completeSSE(w, r)
	}, false)
	graph := config.Governance{
		Schema:    config.SessionNestedSchema,
		OpenNodes: []string{"infer", "gate", "next", "side", "fork-a", "fork-b", "inner-finish", "outer-skip", "finish"},
		WorkflowEdges: [][2]string{
			{"finish", "inner-finish"}, {"finish", "outer-skip"}, {"fork-a", "side"}, {"fork-b", "side"},
			{"gate", "infer"}, {"inner-finish", "fork-a"}, {"inner-finish", "fork-b"}, {"inner-finish", "next"},
			{"next", "gate"}, {"outer-skip", "infer"}, {"side", "gate"},
		},
		WorkflowSelectors: [][3]string{{"gate", "next", "side"}, {"infer", "gate", "outer-skip"}},
	}
	bundle := sessionGraphBundle(t, f, graph, "side", 28)
	root := bundle.Plans[0]
	credentials := `WEAVER_PROVIDER_CREDENTIAL_ENVS={"primary":"WEAVER_TEST_KEY"}`
	if trial != nil {
		credentials = `WEAVER_PROVIDER_CREDENTIAL_ENVS={"primary":"WEAVER_TEST_KEY","backup":"WEAVER_TEST_KEY"}`
		f.env = append(f.env, "WEAVER_TEST_GOVERNOR_TIMING=1")
		if trial.retained {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_RETAINED=1")
		} else {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_RETAINED=0")
		}
		if trial.fullCut {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_FULL_CUT=1")
		} else {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_FULL_CUT=0")
		}
		if trial.namedResult {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_NAMED_RESULT=1")
		} else {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_NAMED_RESULT=0")
		}
		if trial.preopen {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_PREOPEN=1")
		} else {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_PREOPEN=0")
		}
		if trial.changedSources {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_CHANGED_SOURCES=1")
		} else {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_CHANGED_SOURCES=0")
		}
		if trial.packedFacts {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_PACKED_FACTS=1")
		} else {
			f.env = append(f.env, "WEAVER_TEST_GOVERNOR_PACKED_FACTS=0")
		}
	}
	f.env = append(f.env, credentials,
		hardFactFeedSetting(t, f, root.Family, root.Node, graph.WorkflowEdges, nil, graph.Schema, graph.WorkflowSelectors, graph.OpenNodes...))
	policy := compiledControlSources(false)
	policy.configure(t, f, bundle)
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.useProducer(policy.producer)
	if trial != nil {
		defer trial.finish(t, f, c)
	}
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	started := time.Now()
	phase := func(name string) {
		deadline, _ := ctx.Deadline()
		t.Logf("nested Session phase=%s elapsed=%s remaining=%s", name, time.Since(started), time.Until(deadline))
	}
	defer phase("scenario-exit")

	stage := func(revision uint64, prior *pb.HardFactBarrier, available bool) *pb.HardFactBarrier {
		t.Helper()
		snapshot := strings.Repeat("0", 64)
		if prior != nil {
			snapshot = prior.GetSnapshot()
		}
		barrier, err := f.admin.RPC.StageHardFact(f.admin.Context(ctx), &pb.HardFactIntent{
			OperationId: "nested-fact-" + strconv.FormatUint(revision, 10), Domain: "availability",
			Revision: revision, PreviousSnapshot: snapshot, ExpectedFloor: prior.GetFloor(), Available: proto.Bool(available),
		})
		if err != nil || barrier.GetFloor() != revision {
			t.Fatalf("stage nested facts: %v %v", barrier, err)
		}
		return barrier
	}
	resolve := func(barrier *pb.HardFactBarrier) {
		t.Helper()
		result, err := f.admin.RPC.ResolveHardFact(f.admin.Context(ctx), barrier)
		if err != nil || !proto.Equal(result.GetBarrier(), barrier) || len(result.GetAffected()) != len(graph.OpenNodes) {
			t.Fatalf("resolve nested facts: %v %v", result, err)
		}
	}
	inspect := func(node string) (*pb.ProviderReceipt, error) {
		return c.client.RPC.Inspect(c.client.Context(ctx), &pb.OperationKey{Family: root.Family, Node: node})
	}
	missing := func(nodes ...string) {
		t.Helper()
		for _, node := range nodes {
			if receipt, err := inspect(node); status.Code(err) != codes.FailedPrecondition {
				t.Fatalf("unexpected claim for %s: %v %v", node, receipt, err)
			}
		}
	}
	wait := func(node, state string, held uint64) *pb.ProviderReceipt {
		t.Helper()
		tick := time.NewTicker(20 * time.Millisecond)
		defer tick.Stop()
		for {
			r, err := inspect(node)
			if err == nil && r.GetState() == state && r.GetHeld() == held {
				return r
			}
			select {
			case <-tick.C:
			case <-ctx.Done():
				t.Fatalf("%s expected %s with hold %d: %v %v", node, state, held, r, err)
			}
		}
	}
	execute := func() error {
		_, err := c.client.Execute(ctx, root, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
		return err
	}
	replay := func() {
		t.Helper()
		if err := execute(); status.Code(err) != codes.FailedPrecondition {
			t.Fatalf("root replay: %v", err)
		}
	}
	first := stage(1, nil, true)
	resolve(first)
	if outerRight {
		result := make(chan error, 1)
		partial := make(chan struct{}, 1)
		go func() {
			_, err := c.client.Execute(ctx, root, pb.Encoding_PROTOBUF, 1, func(event *pb.Event) error {
				if event.GetKind() == "delta" && event.GetText() == `{"route":"right"}` {
					select {
					case partial <- struct{}{}:
					default:
						return fmt.Errorf("outer selector result repeated before release")
					}
				}
				return nil
			})
			result <- err
		}()
		select {
		case <-partial:
		case err := <-result:
			t.Fatalf("outer selector ended before the gated release: %v", err)
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
		missing("gate", "outer-skip", "finish")
		phase("selector-result-without-terminal-release")
		releaseRoot()
		if err := <-result; err != nil {
			t.Fatal(err)
		}
		wait("finish", "complete", 12)
		wait("outer-skip", "complete", 12)
		missing("gate", "next", "side", "fork-a", "fork-b", "inner-finish")
		replay()
		if f.primary.Load() != 3 || f.backup.Load() != 0 || f.denied.Load() != 0 {
			t.Fatal("inactive nested arm dispatched or join repeated")
		}
		t.Log("outer right skipped the whole undecided nested subtree; one outer join; held=12")
		return
	}
	if trial != nil {
		if err := execute(); err != nil {
			t.Fatal(err)
		}
		seen := map[string]bool{}
		for range 2 {
			select {
			case node := <-arrived:
				seen[node] = true
			case <-ctx.Done():
				t.Fatal("both performance forks must arrive", ctx.Err())
			}
		}
		if !seen["fork-a"] || !seen["fork-b"] {
			t.Fatal("missing independent performance forks", seen)
		}
		releaseA()
		wait("fork-a", "complete", 20)
		missing("next", "outer-skip", "inner-finish", "finish")
		replayResult := trial.offerReplay(ctx, f, policy.producer)
		releaseB()
		wait("finish", "complete", 28)
		wait("inner-finish", "complete", 28)
		missing("next", "outer-skip")
		if replayResult != nil {
			select {
			case err := <-replayResult:
				if err != nil {
					t.Fatal("concurrent prepared-source replay", err)
				}
			case <-ctx.Done():
				t.Fatal("concurrent prepared-source replay deadline", ctx.Err())
			}
		}
		replay()
		if f.primary.Load() != 6 || f.backup.Load() != 1 || f.denied.Load() != 0 {
			t.Fatalf("unexpected performance sends: %d/%d/%d", f.primary.Load(), f.backup.Load(), f.denied.Load())
		}
		phase("joins-completed")
		return
	}
	if err := execute(); err != nil {
		t.Fatal(err)
	}
	queued := wait("side", "queued", 12)
	wait("gate", "complete", 12)
	missing("next", "outer-skip", "fork-a", "fork-b", "inner-finish", "finish")
	replay()
	replay()
	if other := wait("side", "queued", 12); !proto.Equal(queued, other) {
		t.Fatal("duplicate trigger replaced nested decision claim")
	}
	withdrawn := stage(2, first, false)
	phase("withdrawal-staged")
	c.stop(t)
	phase("control-stopped")
	f.stop(t)
	phase("rust-stopped")
	f.env = append(f.env, `WEAVER_PROVIDER_CREDENTIAL_ENVS={"primary":"WEAVER_TEST_KEY","backup":"WEAVER_TEST_KEY"}`)
	f.start(t)
	phase("rust-restarted")
	c.start(t)
	phase("control-restarted")
	if other := stage(2, first, false); !proto.Equal(withdrawn, other) {
		t.Fatal("restart changed pending withdrawal")
	}
	wait("side", "queued", 12)
	resolve(withdrawn)
	replay()
	if other := wait("side", "queued", 12); !proto.Equal(queued, other) || f.primary.Load() != 2 || f.backup.Load() != 0 {
		t.Fatal("withdrawal advanced or replaced nested claim")
	}
	missing("next", "outer-skip", "fork-a", "fork-b", "inner-finish", "finish")
	resolve(stage(3, withdrawn, true))
	phase("availability-restored")
	seen := map[string]bool{}
	for range 2 {
		select {
		case node := <-arrived:
			seen[node] = true
		case <-ctx.Done():
			t.Fatal("parallel children of restored inner right arm did not both dispatch")
		}
	}
	if !seen["fork-a"] || !seen["fork-b"] {
		t.Fatalf("duplicate parallel children: %v", seen)
	}
	phase("parallel-dispatched")
	if complete := wait("side", "complete", 20); complete.GetDigest() != queued.GetDigest() {
		t.Fatal("restored branch changed identity")
	}
	releaseA()
	wait("fork-a", "complete", 20)
	missing("next", "outer-skip", "inner-finish", "finish")
	releaseB()
	wait("finish", "complete", 28)
	phase("joins-completed")
	wait("inner-finish", "complete", 28)
	missing("next", "outer-skip")
	replay()
	if f.primary.Load() != 6 || f.backup.Load() != 1 || f.denied.Load() != 0 {
		t.Fatalf("unexpected nested sends: %d/%d/%d", f.primary.Load(), f.backup.Load(), f.denied.Load())
	}
	t.Log("outer left and inner right survived restart and withdrawal; both parallel releases required; two joins once each; held=28")
}
