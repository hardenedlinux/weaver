// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build proofintegration

package specreview_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/devrunner"
	"github.com/HardenedLinux/weaver/go/internal/specreview"
	"path/filepath"
	"runtime"
	"testing"
	"testing/quick"
	"time"
)

func TestRealSPECQualificationAndProducer(t *testing.T) {
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "../../.."))
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancel()
	artifact, err := devrunner.QualifySpec(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	pub, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	producer, err := specreview.New(artifact.Document, artifact.Digest, "gateway", 0, key)
	if err != nil {
		t.Fatal(err)
	}
	entry, err := producer.Entry("revoke")
	if err != nil {
		t.Fatal(err)
	}
	gain, err := producer.Entry("expansion-refused")
	if err != nil {
		t.Fatal(err)
	}
	if entry.Environments != 3 || entry.Gains != 0 || entry.Losses != 3 || gain.Gains != 3 || gain.Classification != "gain-only" {
		t.Fatal("actual solver coverage/witnesses", entry, gain)
	}
	hash := func(s string) string { v := sha256.Sum256([]byte(s)); return hex.EncodeToString(v[:]) }
	parent, schema := entry.Epoch, hash(entry.Schema)
	p := v1.Publication{OperationID: "revoke", ExpectedRevision: &parent, Fence: 2, Policy: entry.AfterPolicy, Schema: entry.Schema}
	digest, _ := p.Digest()
	observed := &pb.PublicationReviewContext{Publication: &pb.PublicationKey{OperationId: p.OperationID, Digest: digest}, Parent: &pb.AuthorityParent{Revision: entry.Epoch, Fence: 1, PolicyDigest: hash(entry.BeforePolicy), SchemaDigest: &schema}, Reviewer: &pb.ReviewAuthority{Audience: "gateway", Epoch: 0, PublicKey: hex.EncodeToString(pub), QualifiedCatalog: &artifact.Digest}, Source: &pb.SourceAuthorityView{Epoch: 0, IdentityDigest: hash("source")}}
	proof, err := producer.Issue(p, observed)
	if err != nil || proof.Disposition != v1.DeltaNoExecutionGain {
		t.Fatal(proof, err)
	}
	// Every substituted parent remains denied even when all signature plumbing is genuine.
	if err := quick.Check(func(epoch uint16) bool {
		if uint64(epoch) == entry.Epoch {
			return true
		}
		c := *observed
		v := *observed.Parent
		v.Revision = uint64(epoch)
		c.Parent = &v
		_, err := producer.Issue(p, &c)
		return err != nil
	}, &quick.Config{MaxCount: 128}); err != nil {
		t.Fatal(err)
	}
	t.Run("forged-current-reviewer-epoch", func(t *testing.T) {
		// Even if the caller changes both context and request observations, issuer
		// custody is bound to its own configured epoch, not the observed value.
		c := *observed
		reviewer := *observed.Reviewer
		reviewer.Epoch++
		c.Reviewer = &reviewer
		if _, err := producer.Issue(p, &c); err == nil {
			t.Fatal("caller promoted issuer epoch")
		}
	})
	p.Policy = gain.AfterPolicy
	p.ExpectedRevision = &gain.Epoch
	digest, _ = p.Digest()
	observed.Publication.Digest = digest
	observed.Parent.Revision = gain.Epoch
	observed.Parent.PolicyDigest = hash(gain.BeforePolicy)
	if _, err := producer.Issue(p, observed); err == nil {
		t.Fatal("actual gain was signed as NoGain")
	}
	t.Run("missing-solver-cannot-qualify", func(t *testing.T) {
		t.Setenv("CVC5", filepath.Join(t.TempDir(), "absent-cvc5"))
		if _, err := devrunner.QualifySpec(ctx, root); err == nil {
			t.Fatal("missing solver produced qualification")
		}
	})

}
