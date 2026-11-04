// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/devrunner"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/specreview"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestProviderRealSPECReviewRevocationLostRepliesAndRestart(t *testing.T) {
	qualificationCtx, qualificationCancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer qualificationCancel()
	qualified, err := devrunner.QualifySpec(qualificationCtx, root(t))
	if err != nil {
		t.Fatal(err)
	}
	tail := make(chan struct{})
	var once sync.Once
	t.Cleanup(func() { once.Do(func() { close(tail) }) })
	f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		emitChunk(w, "prefix", false)
		select {
		case <-tail:
			emitChunk(w, "forbidden-tail", false)
			fmt.Fprint(w, "data: [DONE]\n\n")
		case <-r.Context().Done():
		}
	}, false)
	producer, err := specreview.New(qualified.Document, qualified.Digest, "test-gateway", 1, f.reviewKey)
	if err != nil {
		t.Fatal(err)
	}
	active, err := producer.Entry("activate")
	if err != nil {
		t.Fatal(err)
	}
	revoked, err := producer.Entry("revoke")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	// Explicit deployment migration is not called NoGain. Then install the real
	// qualified producer and disable expansion approvals before exercising effects.
	revision := uint64(0)
	setup := v1.Publication{OperationID: "deploy-qualified-model", ExpectedRevision: &revision, Fence: 2, Policy: active.BeforePolicy, Schema: active.Schema}
	if _, err = f.admin.Publish(ctx, setup); err != nil {
		t.Fatal("explicit deployment", err)
	}
	f.policy, f.schema = active.BeforePolicy, active.Schema
	f.stop(t)
	config, err := json.Marshal(struct {
		Audience       string `json:"audience"`
		Epoch          uint64 `json:"epoch"`
		PublicKey      string `json:"public_key"`
		AllowExpansion bool   `json:"allow_expansion"`
		Catalog        string `json:"qualified_catalog"`
	}{"test-gateway", 1, hex.EncodeToString(f.reviewKey.Public().(ed25519.PublicKey)), false, qualified.Digest})
	if err != nil {
		t.Fatal(err)
	}
	for i, v := range f.env {
		if strings.HasPrefix(v, "WEAVER_REVIEW_AUTHORITY=") {
			f.env[i] = "WEAVER_REVIEW_AUTHORITY=" + string(config)
		}
	}
	f.start(t)
	rawClient := func() gatewayclient.Client {
		c := *f.admin
		c.RPC = f.admin.RPC.(*fixtureReviewer).GatewayClient
		return c
	}
	client := rawClient()
	issue := func(p v1.Publication) v1.Publication {
		t.Helper()
		if err := client.StageReviewedPublication(ctx, p); err != nil {
			t.Fatal(err)
		}
		observed, err := client.ReviewContext(ctx, p)
		if err != nil {
			t.Fatal(err)
		}
		proof, err := producer.Issue(p, observed)
		if err != nil {
			t.Fatal(err)
		}
		p.Review = &proof
		return p
	}
	revision = 1
	activation := issue(v1.Publication{OperationID: "qualified-activation", ExpectedRevision: &revision, Fence: 3, Policy: active.AfterPolicy, Schema: active.Schema})
	sibling := issue(v1.Publication{OperationID: "qualified-old-parent", ExpectedRevision: &revision, Fence: 3, Policy: active.AfterPolicy, Schema: active.Schema})
	if err = client.RegisterReview(ctx, sibling, *sibling.Review); err != nil {
		t.Fatal(err)
	}
	bundle := controlBundle(t, f)
	bundle.Publication = activation
	for i := range bundle.Plans {
		bundle.Plans[i].Revision, bundle.Plans[i].Fence = 2, 3
	}
	payload, err := json.Marshal(bundle)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "qualified-control.json")
	if err = os.WriteFile(path, payload, 0600); err != nil {
		t.Fatal(err)
	}
	control := newControlProcess(t, f, path)
	control.start(t)
	if rejected, err := client.FinalizePublication(ctx, sibling); err != gatewayclient.ErrPublicationRejected || rejected.GetOutcome() != pb.PublicationOutcome_REJECTED {
		t.Fatal("qualified old parent rebased or lost original outcome", rejected, err)
	}
	f.plan = bundle.Plans[0]
	inspectOriginal := func() *pb.ProviderReceipt {
		t.Helper()
		receipt, err := f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: f.plan.Family, Node: f.plan.Node})
		if err != nil {
			t.Fatal(err)
		}
		return receipt
	}
	prefix := make(chan struct{}, 1)
	ended := make(chan error, 1)
	go func() {
		_, err := control.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, func(e *pb.Event) error {
			if e.Text == "prefix" {
				select {
				case prefix <- struct{}{}:
				default:
				}
			}
			return nil
		})
		ended <- err
	}()
	select {
	case <-prefix:
	case err := <-ended:
		t.Fatalf("qualified execution ended before prefix: %v (primary=%d denied=%d)", err, f.primary.Load(), f.denied.Load())
	case <-ctx.Done():
		t.Fatal("qualified positive control missing")
	}
	revision = 2
	p := issue(v1.Publication{OperationID: "qualified-revoke", ExpectedRevision: &revision, Fence: 4, Policy: revoked.AfterPolicy, Schema: revoked.Schema})
	// An actually signed but changed report cannot replace deployment qualification.
	forged := p.Review.Clone()
	forged.Delta += " "
	message, _ := forged.SigningDigest()
	bytes, _ := hex.DecodeString(message)
	forged.Signature = hex.EncodeToString(ed25519.Sign(f.reviewKey, bytes))
	if err := client.RegisterReview(ctx, p, forged); err == nil {
		t.Fatal("signed unqualified report admitted")
	}
	loss := &reviewReplyLoss{GatewayClient: client.RPC}
	loss.registration.Store(true)
	client.RPC = loss
	if _, err := client.FinalizePublication(ctx, p); status.Code(err) != codes.Unavailable {
		t.Fatal("actual registration response loss", err)
	}
	if loss.publishCalls.Load() != 0 {
		t.Fatal("unknown registration bypassed final CAS")
	}
	once.Do(func() { close(tail) })
	if err := <-ended; err == nil {
		t.Fatal("pending qualified revocation released tail")
	}
	if inspectOriginal().Held != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatal("unknown exposure lost after partial stream")
	}
	f.stop(t)
	f.start(t)
	client = rawClient()
	loss = &reviewReplyLoss{GatewayClient: client.RPC}
	loss.publication.Store(true)
	client.RPC = loss
	if _, err := client.FinalizePublication(ctx, p); status.Code(err) != codes.Unavailable {
		t.Fatal("actual qualified commit response loss", err)
	}
	receipt, err := client.InspectPublication(ctx, p)
	if err != nil || receipt.GetRevision() != 3 || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatal(receipt, err)
	}
	f.plan.Revision, f.plan.Fence = 3, 4
	if _, _, err := execute(t, f, pb.Encoding_ARROW_IPC, 2); err == nil {
		t.Fatal("qualified revoke failed final use")
	}
	f.stop(t)
	f.start(t)
	client = rawClient()
	if again, err := client.InspectPublication(ctx, p); err != nil || again.GetDigest() != receipt.GetDigest() {
		t.Fatal("original outcome lost", again, err)
	}
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err == nil || inspectOriginal().Held != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatal("restart reopened claim or released unknown budget", err)
	}
}
