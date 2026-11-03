// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package gatewayclient

import (
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"google.golang.org/protobuf/proto"
	"testing"
)

func TestPublicationReceiptCannotReplaceOriginalIdentityParentOrDecision(t *testing.T) {
	parent, fence, next := uint64(4), uint64(8), uint64(5)
	proposal := v1.Publication{OperationID: "change", ExpectedRevision: &parent, Fence: fence, Policy: "permit(principal,action,resource);", Schema: "{}"}
	digest, err := proposal.Digest()
	if err != nil {
		t.Fatal(err)
	}
	good := &pb.PublicationReceipt{OperationId: proposal.OperationID, Digest: digest, Outcome: pb.PublicationOutcome_COMMITTED, Revision: &next, Fence: &fence}
	if err := validatePublication(proposal, digest, good); err != nil {
		t.Fatal(err)
	}
	mutations := []func(*pb.PublicationReceipt){
		func(r *pb.PublicationReceipt) { r.OperationId = "replacement" }, func(r *pb.PublicationReceipt) { r.Digest = "forged" },
		func(r *pb.PublicationReceipt) { r.Revision = nil }, func(r *pb.PublicationReceipt) { r.Fence = nil },
		func(r *pb.PublicationReceipt) { wrong := uint64(6); r.Revision = &wrong }, func(r *pb.PublicationReceipt) { r.Outcome = pb.PublicationOutcome_PUBLICATION_OUTCOME_UNSPECIFIED },
		func(r *pb.PublicationReceipt) { wrong := uint64(9); r.Fence = &wrong },
	}
	for i, mutate := range mutations {
		r := proto.Clone(good).(*pb.PublicationReceipt)
		mutate(r)
		if validatePublication(proposal, digest, r) == nil {
			t.Fatalf("accepted mutation %d", i)
		}
	}
}
