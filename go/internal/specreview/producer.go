// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Package specreview owns independent, deployment-qualified review issuance.
// It contains no solver, Cedar evaluator, publication client or send operation.
package specreview

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
)

// Producer holds independent issuer custody and a deployment-pinned SPEC output.
// No request can replace the catalog or supply a qualification verdict.
type Producer struct {
	epoch                      uint64
	audience, document, digest string
	catalog                    v1.QualifiedDeltaCatalog
	key                        ed25519.PrivateKey
}

func hash(s string) string { sum := sha256.Sum256([]byte(s)); return hex.EncodeToString(sum[:]) }

// New admits an already qualified deployment artifact, not an arbitrary report.
// expectedDigest is trusted deployment input, separate from caller/request data.
func New(document []byte, expectedDigest, audience string, epoch uint64, key ed25519.PrivateKey) (*Producer, error) {
	if len(document) == 0 || len(document) > 65536 || hash(string(document)) != expectedDigest || len(key) != ed25519.PrivateKeySize || audience == "" {
		return nil, errors.New("SPEC deployment qualification binding")
	}
	catalog, err := v1.Decode[v1.QualifiedDeltaCatalog](document)
	if err != nil {
		return nil, err
	}
	if catalog.Engine != "cedar-poo-spec.exact-error-free-allow" || catalog.Qualification != "solver-checked" || len(catalog.Entries) == 0 || len(catalog.Entries) > 64 {
		return nil, errors.New("SPEC qualification kind/scope")
	}
	names := map[string]bool{}
	for _, entry := range catalog.Entries {
		if entry.Name == "" || names[entry.Name] || entry.Environments == 0 || entry.BeforePolicy == "" || entry.AfterPolicy == "" || entry.Schema == "" {
			return nil, errors.New("SPEC qualification entry")
		}
		names[entry.Name] = true
	}
	return &Producer{epoch: epoch, audience: audience, document: string(document), digest: expectedDigest, catalog: catalog, key: append(ed25519.PrivateKey(nil), key...)}, nil
}

// Entry exposes immutable deployment data by value, never issuer custody.
func (p *Producer) Entry(name string) (v1.QualifiedDeltaEntry, error) {
	for _, e := range p.catalog.Entries {
		if e.Name == name {
			return e, nil
		}
	}
	return v1.QualifiedDeltaEntry{}, errors.New("unknown qualified revision")
}

// Issue binds genuine qualified policies to one actual original publication.
// Context is observation: Rust must still recheck source, parent and issuer at CAS.
func (p *Producer) Issue(change v1.Publication, c *pb.PublicationReviewContext) (v1.DeltaReview, error) {
	change = change.Clone()
	digest, err := change.Digest()
	if err != nil {
		return v1.DeltaReview{}, err
	}
	if c == nil || c.Publication == nil || c.Reviewer == nil || c.Source == nil || c.Publication.OperationId != change.OperationID || c.Publication.Digest != digest || c.Reviewer.Audience != p.audience || c.Reviewer.Epoch != p.epoch || c.Reviewer.GetQualifiedCatalog() != p.digest || c.Reviewer.PublicKey != hex.EncodeToString(p.key.Public().(ed25519.PublicKey)) {
		return v1.DeltaReview{}, errors.New("review issuer/original context")
	}
	for _, entry := range p.catalog.Entries {
		if entry.Gains != 0 || entry.Environments == 0 || (entry.Classification != "loss-only" && entry.Classification != "equivalent-in-schema") || entry.AfterPolicy != change.Policy || entry.Schema != change.Schema {
			continue
		}
		kind := v1.DeltaNoExecutionGain
		var parent *v1.AuthorityParent
		if c.Parent == nil {
			if change.ExpectedRevision != nil || entry.Name != "bootstrap" || entry.Epoch != 0 || entry.BeforePolicy != entry.AfterPolicy {
				continue
			}
			kind = v1.DeltaBootstrap
		} else {
			if entry.Name == "bootstrap" || change.ExpectedRevision == nil || *change.ExpectedRevision != c.Parent.Revision || entry.Epoch != c.Parent.Revision || hash(entry.BeforePolicy) != c.Parent.PolicyDigest || c.Parent.SchemaDigest == nil || hash(entry.Schema) != *c.Parent.SchemaDigest {
				continue
			}
			parent = &v1.AuthorityParent{Revision: c.Parent.Revision, Fence: c.Parent.Fence, PolicyDigest: c.Parent.PolicyDigest, SchemaDigest: c.Parent.SchemaDigest}
		}
		evidence := v1.DeltaReview{Review: v1.PublicationReview{Publication: v1.PublicationKey{OperationID: change.OperationID, Digest: digest}, Parent: parent, Artifact: entry.Name}, Audience: p.audience, ReviewerEpoch: c.Reviewer.Epoch, SourceEpoch: c.Source.Epoch, SourceIdentityDigest: c.Source.IdentityDigest, Disposition: kind, Delta: p.document}
		evidence = evidence.Clone()
		message, err := evidence.SigningDigest()
		if err != nil {
			return v1.DeltaReview{}, err
		}
		raw, err := hex.DecodeString(message)
		if err != nil {
			return v1.DeltaReview{}, err
		}
		evidence.Signature = hex.EncodeToString(ed25519.Sign(p.key, raw))
		return evidence, nil
	}
	return v1.DeltaReview{}, errors.New("SPEC did not qualify this exact revision/epoch")
}
