// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"math/big"
	"testing"
	"time"
)

type lostRotationReply struct {
	pb.GatewayClient
	lost bool
}

func (p *lostRotationReply) RotateSourceAuthority(ctx context.Context, in *pb.SourceRotationRequest, opts ...grpc.CallOption) (*pb.SourceRotationReceipt, error) {
	receipt, err := p.GatewayClient.RotateSourceAuthority(ctx, in, opts...)
	if err == nil && !p.lost {
		p.lost = true
		return nil, status.Error(codes.Unavailable, "injected reply loss after durable source handoff")
	}
	return receipt, err
}

func reissueSourceKey(t *testing.T, f *fixture, old tls.Certificate) []byte {
	t.Helper()
	leaf, err := x509.ParseCertificate(old.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(f.pki.ca)
	if block == nil {
		t.Fatal("CA fixture PEM missing")
	}
	ca, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := x509.ParseECPrivateKey(f.pki.key)
	if err != nil {
		t.Fatal(err)
	}
	leaf.SerialNumber = big.NewInt(9001)
	der, err := x509.CreateCertificate(rand.Reader, leaf, ca, old.PrivateKey.(crypto.Signer).Public(), signer)
	if err != nil {
		t.Fatal(err)
	}
	return der
}

func TestProviderPersistentSourceRotationLostReplyFencesExistingWorkerAndReissuedKey(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	old := f.pki.source
	next := secondaryClient(t, f.pki)
	role := sha256.Sum256([]byte(f.admin.Token))
	command := v1.SourceRotation{OperationID: "durable-source-handoff", ExpectedEpoch: 0, NextCertificate: next.Certificate[0], NextCredentialSHA256: hex.EncodeToString(role[:])}
	alias := command
	alias.OperationID = "operation-peer-alias"
	alias.NextCertificate = f.pki.client.Certificate[0]
	if _, err := f.admin.RotateSource(ctx, alias); status.Code(err) != codes.InvalidArgument {
		t.Fatal("source successor accepted operation certificate alias", err)
	}
	alias = command
	alias.OperationID = "operation-token-alias"
	operation := sha256.Sum256([]byte(ownerToken))
	alias.NextCredentialSHA256 = hex.EncodeToString(operation[:])
	if _, err := f.admin.RotateSource(ctx, alias); status.Code(err) != codes.InvalidArgument {
		t.Fatal("source successor accepted operation credential alias", err)
	}
	f.admin.RPC = &lostRotationReply{GatewayClient: f.admin.RPC}
	if _, err := f.admin.RotateSource(ctx, command); status.Code(err) != codes.Unavailable {
		t.Fatal("expected unknown durable handoff", err)
	}
	if _, err := f.admin.Publish(ctx, pendingChange(f, "old-live-worker")); status.Code(err) != codes.PermissionDenied {
		t.Fatal("old live source connection bypassed persistent floor", err)
	}
	recovered, err := f.admin.RotateSource(ctx, command)
	if err != nil || recovered.Outcome != pb.SourceRotationOutcome_SOURCE_ROTATED || recovered.Authority.Epoch != 1 {
		t.Fatal("exact original handoff observation", recovered, err)
	}
	// This returned historical receipt cannot authorize the retired source again.
	if _, err = f.admin.SourceAuthority(ctx); status.Code(err) != codes.PermissionDenied {
		t.Fatal("historical receipt restored source permission", err)
	}
	restartWithSourceCertificate(t, f, next)
	view, err := f.admin.SourceAuthority(ctx)
	if err != nil || view.Epoch != 1 {
		t.Fatal("current source recovery", view, err)
	}
	reissued := command
	reissued.OperationID = "reissued-retired-key"
	reissued.ExpectedEpoch = 1
	reissued.NextCertificate = reissueSourceKey(t, f, old)
	receipt, err := f.admin.RotateSource(ctx, reissued)
	if err != gatewayclient.ErrSourceRotationRejected || receipt.Authority.Epoch != 1 {
		t.Fatal("same old private key regained source authority under a new certificate", receipt, err)
	}
	if _, err = f.client.RPC.RotateSourceAuthority(f.client.Context(ctx), &pb.SourceRotationRequest{}); status.Code(err) != codes.PermissionDenied {
		t.Fatal("operation ingress exposed source handoff", err)
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("source handoff sent provider traffic")
	}
}
