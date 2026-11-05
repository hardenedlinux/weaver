// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package v1

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"unicode/utf8"
)

type AuthorityParent struct {
	Revision     uint64  `json:"revision"`
	Fence        uint64  `json:"fence"`
	PolicyDigest string  `json:"policy_digest"`
	SchemaDigest *string `json:"schema_digest"`
}
type PublicationKey struct {
	OperationID string `json:"operation_id"`
	Digest      string `json:"digest"`
}
type PublicationReview struct {
	Publication PublicationKey   `json:"publication"`
	Parent      *AuthorityParent `json:"parent"`
	Artifact    string           `json:"artifact"`
}
type DeltaDisposition string

const (
	DeltaBootstrap        DeltaDisposition = "bootstrap"
	DeltaNoExecutionGain  DeltaDisposition = "no_execution_gain"
	DeltaExplicitApproval DeltaDisposition = "explicit_approval"
)

type DeltaReview struct {
	Review               PublicationReview `json:"review"`
	Audience             string            `json:"audience"`
	ReviewerEpoch        uint64            `json:"reviewer_epoch"`
	SourceEpoch          uint64            `json:"source_epoch"`
	SourceIdentityDigest string            `json:"source_identity_digest"`
	Disposition          DeltaDisposition  `json:"disposition"`
	Delta                string            `json:"delta"`
	Signature            string            `json:"signature"`
}

func reviewHex(value string, size int) bool {
	if len(value) != size {
		return false
	}
	for _, c := range []byte(value) {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func reviewID(value string) bool {
	if len(value) == 0 || len(value) > 128 {
		return false
	}
	for _, c := range []byte(value) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == ':' || c == '-') {
			return false
		}
	}
	return true
}
func reviewHash(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}
func (r PublicationReview) Digest() (string, error) {
	if !reviewID(r.Publication.OperationID) || !reviewHex(r.Publication.Digest, 64) || len(r.Artifact) == 0 || len(r.Artifact) > 65536 || !utf8.ValidString(r.Artifact) {
		return "", errors.New("review binding")
	}
	if p := r.Parent; p != nil && (p.Revision > math.MaxInt64 || p.Fence > math.MaxInt64 || !reviewHex(p.PolicyDigest, 64) || (p.SchemaDigest != nil && !reviewHex(*p.SchemaDigest, 64))) {
		return "", errors.New("review parent")
	}
	publication, err := json.Marshal(r.Publication)
	if err != nil {
		return "", err
	}
	parent, err := json.Marshal(r.Parent)
	if err != nil {
		return "", err
	}
	return reviewTuple(reviewText("weaver.publication-review.v1"), publication, parent, reviewText(reviewHash(r.Artifact)))
}

// SigningDigest binds bytes and identities. It does not verify SPEC Delta semantics.
func (r DeltaReview) SigningDigest() (string, error) {
	reviewed, err := r.Review.Digest()
	if err != nil {
		return "", err
	}
	if !reviewID(r.Audience) || r.ReviewerEpoch > math.MaxInt64 || r.SourceEpoch > math.MaxInt64 || !reviewHex(r.SourceIdentityDigest, 64) || len(r.Delta) == 0 || len(r.Delta) > 65536 || !utf8.ValidString(r.Delta) {
		return "", errors.New("Delta evidence bounds")
	}
	switch r.Disposition {
	case DeltaBootstrap, DeltaNoExecutionGain, DeltaExplicitApproval:
	default:
		return "", errors.New("Delta disposition")
	}
	return reviewTuple(reviewText("weaver.authority-delta-review.v1"), reviewText(r.Audience), json.RawMessage(strconv.FormatUint(r.ReviewerEpoch, 10)), json.RawMessage(strconv.FormatUint(r.SourceEpoch, 10)), reviewText(r.SourceIdentityDigest), reviewText(reviewed), reviewText(string(r.Disposition)), reviewText(reviewHash(r.Delta)))
}

// Clone keeps the caller's parent/schema pointers out of an asynchronous handoff.
func (r DeltaReview) Clone() DeltaReview {
	if p := r.Review.Parent; p != nil {
		parent := *p
		if p.SchemaDigest != nil {
			schema := *p.SchemaDigest
			parent.SchemaDigest = &schema
		}
		r.Review.Parent = &parent
	}
	return r
}

func reviewText(value string) json.RawMessage { encoded, _ := json.Marshal(value); return encoded }
func reviewTuple(parts ...json.RawMessage) (string, error) {
	encoded, err := json.Marshal(parts)
	if err != nil {
		return "", err
	}
	return reviewHash(string(encoded)), nil
}
