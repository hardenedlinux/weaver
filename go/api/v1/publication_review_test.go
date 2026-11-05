// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package v1

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"strings"
	"testing"
	"testing/quick"
)

// Synthetic crypto fixture, not a SPEC proof producer or review approval.
func reviewFixture(t testing.TB) (DeltaReview, ed25519.PrivateKey) {
	t.Helper()
	identity, err := (SourceIdentity{strings.Repeat("1", 64), strings.Repeat("2", 64), strings.Repeat("3", 64)}).Digest()
	if err != nil {
		t.Fatal(err)
	}
	return DeltaReview{Review: PublicationReview{Publication: PublicationKey{"original", strings.Repeat("4", 64)}, Artifact: "replay bytes"}, Audience: "test-gateway", SourceIdentityDigest: identity, Disposition: DeltaBootstrap, Delta: "opaque external review evidence"}, ed25519.NewKeyFromSeed(bytes.Repeat([]byte{23}, ed25519.SeedSize))
}
func TestDeltaReviewSignatureInterop(t *testing.T) {
	review, key := reviewFixture(t)
	digest, err := review.SigningDigest()
	if err != nil {
		t.Fatal(err)
	}
	message, err := hex.DecodeString(digest)
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(key, message)
	if digest != "632ac5780990746b2b485011cc9bcc05d6b34d83b2d22709a8339e5a8fea7351" || hex.EncodeToString(signature) != "f35db4b4a9cb1a1d7fdc095af873e3286fa3dee1749d4fe5ecb84f5aaee6d655e77f6f20a650d6946171f69cc9bc83efe5fcac7c0b3f2db27689179eba964807" {
		t.Fatal("cross-language review binding vector changed")
	}

	t.Logf("review signing_digest=%s signature=%s", digest, hex.EncodeToString(signature))
	if !ed25519.Verify(key.Public().(ed25519.PublicKey), message, signature) {
		t.Fatal("fixture signature")
	}
}
func TestDeltaReviewSignedCoordinatesCannotBeRebound(t *testing.T) {
	original, key := reviewFixture(t)
	digest, err := original.SigningDigest()
	if err != nil {
		t.Fatal(err)
	}
	message, _ := hex.DecodeString(digest)
	signature := ed25519.Sign(key, message)
	property := func(field uint8) bool {
		changed := original.Clone()
		switch field % 10 {
		case 0:
			changed.Audience = "other-gateway"
		case 1:
			changed.ReviewerEpoch++
		case 2:
			changed.SourceEpoch++
		case 3:
			changed.SourceIdentityDigest = strings.Repeat("5", 64)
		case 4:
			changed.Review.Publication.OperationID = "renamed"
		case 5:
			changed.Review.Publication.Digest = strings.Repeat("6", 64)
		case 6:
			changed.Review.Artifact += " "
		case 7:
			changed.Delta += " "
		case 8:
			changed.Disposition = DeltaExplicitApproval
		case 9:
			changed.Review.Parent = &AuthorityParent{0, 1, strings.Repeat("7", 64), nil}
		}
		rebound, err := changed.SigningDigest()
		if err != nil {
			return true
		}
		bytes, err := hex.DecodeString(rebound)
		return err == nil && !ed25519.Verify(key.Public().(ed25519.PublicKey), bytes, signature)
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 256}); err != nil {
		t.Fatal(err)
	}
}
func TestDeltaReviewCloneRetainsNullableOriginalParent(t *testing.T) {
	original, _ := reviewFixture(t)
	schema := strings.Repeat("8", 64)
	original.Review.Parent = &AuthorityParent{0, 1, strings.Repeat("7", 64), &schema}
	clone := original.Clone()
	before, err := clone.SigningDigest()
	if err != nil {
		t.Fatal(err)
	}
	*original.Review.Parent.SchemaDigest = strings.Repeat("9", 64)
	original.Review.Parent.Fence++
	after, err := clone.SigningDigest()
	if err != nil || before != after {
		t.Fatal("caller changed frozen review parent", err)
	}
}
