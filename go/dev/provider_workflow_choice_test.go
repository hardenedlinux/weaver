// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && schemeintegration && !windows

package dev

import (
	"context"
	"fmt"
	"io"
	"net/http"
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

func TestProviderControlSessionChoiceFromReleasedResult(t *testing.T) {
	for _, tc := range []struct{ name, result, selected, skipped string }{
		{"left", `{"route":"left"}`, "next", "side"},
		{"right-restart-withdrawal", `{"route":"right"}`, "side", "next"},
		{"duplicate-result-field", `{"route":"left","route":"right"}`, "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			checkSessionChoice(t, tc.result, tc.selected, tc.skipped)
		})
	}
}

func checkSessionChoice(t *testing.T, document, selected, skipped string) {
	t.Helper()
	restart := selected == "side"
	entered, release := make(chan struct{}, 1), make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	defer unblock()
	f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Error(err)
			return
		}
		if !strings.Contains(string(body), `"content":"hello"`) {
			completeSSE(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		emitChunk(w, document[:8], false)
		select {
		case entered <- struct{}{}:
		default:
			t.Error("duplicate selector send")
		}
		select {
		case <-release:
		case <-r.Context().Done():
			return
		}
		if selected == "next" {
			emitChunk(w, document[8:], true)
		} else {
			emitChunk(w, document[8:], false)
			emitChunk(w, "", true)
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
	}, false)
	backup := ""
	if restart {
		backup = selected
	}
	bundle := graphSessionBundle(t, f, config.SessionChoiceSchema, backup, 12)
	root := bundle.Plans[0]
	f.env = append(f.env, `WEAVER_PROVIDER_CREDENTIAL_ENVS={"primary":"WEAVER_TEST_KEY"}`,
		hardFactFeedSetting(t, f, root.Family, root.Node, bundle.Governance.WorkflowEdges, nil, config.SessionChoiceSchema, nil, bundle.Governance.OpenNodes...))
	policy := compiledControlSources(false)
	policy.configure(t, f, bundle)
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.useProducer(policy.producer)
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()

	stage := func(revision uint64, prior *pb.HardFactBarrier, available bool) *pb.HardFactBarrier {
		t.Helper()
		snapshot := strings.Repeat("0", 64)
		if prior != nil {
			snapshot = prior.GetSnapshot()
		}
		barrier, err := f.admin.RPC.StageHardFact(f.admin.Context(ctx), &pb.HardFactIntent{
			OperationId: "choice-fact-" + strconv.FormatUint(revision, 10), Domain: "availability",
			Revision: revision, PreviousSnapshot: snapshot, ExpectedFloor: prior.GetFloor(), Available: proto.Bool(available),
		})
		if err != nil || barrier.GetFloor() != revision {
			t.Fatalf("stage choice facts: %v %v", barrier, err)
		}
		return barrier
	}
	resolve := func(barrier *pb.HardFactBarrier) {
		t.Helper()
		result, err := f.admin.RPC.ResolveHardFact(f.admin.Context(ctx), barrier)
		if err != nil || !proto.Equal(result.GetBarrier(), barrier) || strings.Join(result.GetAffected(), ",") != "finish,infer,next,side" {
			t.Fatalf("resolve choice facts: %v %v", result, err)
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
			t.Fatalf("selector replay: %v", err)
		}
	}

	a := stage(1, nil, true)
	resolve(a)
	result := make(chan error, 1)
	go func() { result <- execute() }()
	select {
	case <-entered:
	case err := <-result:
		t.Fatalf("selector did not emit: %v", err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	missing("next", "side", "finish")
	unblock()
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	if selected == "" {
		replay()
		until := time.Now().Add(150 * time.Millisecond)
		for time.Now().Before(until) {
			missing("next", "side", "finish")
			time.Sleep(10 * time.Millisecond)
		}
		wait("infer", "complete", 4)
		if f.primary.Load() != 1 || f.backup.Load() != 0 {
			t.Fatal("ambiguous structured result dispatched a branch")
		}
		t.Log("ambiguous structured result left the frontier unadvanced")
		return
	}
	if restart {
		queued := wait(selected, "queued", 8)
		replay()
		replay()
		if replayed := wait(selected, "queued", 8); !proto.Equal(queued, replayed) {
			t.Fatal("duplicate wake changed the selected claim")
		}
		missing(skipped, "finish")
		b := stage(2, a, false)
		c.stop(t)
		f.stop(t)
		f.env = append(f.env, `WEAVER_PROVIDER_CREDENTIAL_ENVS={"primary":"WEAVER_TEST_KEY","backup":"WEAVER_TEST_KEY"}`)
		f.start(t)
		c.start(t)
		if replayed := stage(2, a, false); !proto.Equal(b, replayed) {
			t.Fatal("restart changed withdrawal intent")
		}
		wait(selected, "queued", 8)
		resolve(b)
		replay()
		if replayed := wait(selected, "queued", 8); !proto.Equal(queued, replayed) {
			t.Fatal("withdrawal changed the selected claim")
		}
		missing(skipped, "finish")
		if f.primary.Load() != 1 || f.backup.Load() != 0 {
			t.Fatal("pending or resolved withdrawal released a branch")
		}
		resolve(stage(3, b, true))
		if complete := wait(selected, "complete", 12); complete.GetDigest() != queued.GetDigest() {
			t.Fatal("restart replaced selected branch")
		}
	}
	wait("finish", "complete", 12)
	wait(selected, "complete", 12)
	missing(skipped)
	replay()
	primary, secondary := int64(3), int64(0)
	if restart {
		primary, secondary = 2, 1
	}
	if f.primary.Load() != primary || f.backup.Load() != secondary || f.denied.Load() != 0 {
		t.Fatalf("conditional sends = %d/%d/%d, want %d/%d/0", f.primary.Load(), f.backup.Load(), f.denied.Load(), primary, secondary)
	}
	t.Logf("selected %s, skipped %s, one join, held=12, restart=%v", selected, skipped, restart)
}
