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
	"unicode/utf8"
)

// Publication is retained unchanged across an ambiguous response and reconciliation.
type Publication struct {
	OperationID      string       `json:"operation_id"`
	ExpectedRevision *uint64      `json:"expected_revision"`
	Fence            uint64       `json:"fence"`
	Policy           string       `json:"policy"`
	Schema           string       `json:"schema"`
	Review           *DeltaReview `json:"review,omitempty"`
}

func (p Publication) Digest() (string, error) {
	if len(p.OperationID) == 0 || len(p.OperationID) > 128 || p.Fence > math.MaxInt64 || (p.ExpectedRevision != nil && *p.ExpectedRevision > math.MaxInt64) || len(p.Policy) == 0 || len(p.Policy) > 65536 || len(p.Schema) == 0 || len(p.Schema) > 65536 || !utf8.ValidString(p.Policy) || !utf8.ValidString(p.Schema) {
		return "", errors.New("publication bounds")
	}
	for _, c := range []byte(p.OperationID) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == ':' || c == '-') {
			return "", errors.New("publication identity")
		}
	}
	policy, schema := sha256.Sum256([]byte(p.Policy)), sha256.Sum256([]byte(p.Schema))
	data, err := json.Marshal([]any{"weaver.authority-publication.v1", p.OperationID, p.ExpectedRevision, p.Fence, hex.EncodeToString(policy[:]), hex.EncodeToString(schema[:])})
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

// Clone freezes independently issued evidence along with the original CAS parent.
// Review is excluded from Digest because it signs that original command digest.
func (p Publication) Clone() Publication {
	if p.ExpectedRevision != nil {
		value := *p.ExpectedRevision
		p.ExpectedRevision = &value
	}
	if p.Review != nil {
		value := p.Review.Clone()
		p.Review = &value
	}
	return p
}
