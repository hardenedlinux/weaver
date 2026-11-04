// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"strings"

	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

// Rust accepts the first-hop observation only from the pinned relay certificate
// and only with an issuer-signed child grant bound to that same TLS sender.
func (g *Gateway) providerContext(ctx context.Context) (context.Context, error) {
	if !g.oauthRelay {
		return ctx, nil
	}
	const ingress = "weaver-provider-oauth-ingress-cert"
	md, _ := metadata.FromIncomingContext(ctx)
	values := md.Get("weaver-provider-oauth")
	if len(values) != 1 || len(md.Get(ingress)) != 0 {
		return nil, status.Error(codes.Unauthenticated, "unambiguous delegated credential required")
	}
	token, ok := strings.CutPrefix(values[0], "Bearer ")
	if !ok || len(token) < 32 || len(token) > 256 {
		return nil, status.Error(codes.Unauthenticated, "invalid delegated credential")
	}
	for _, c := range []byte(token) {
		if c < 33 || c > 126 {
			return nil, status.Error(codes.Unauthenticated, "invalid delegated credential")
		}
	}
	p, ok := peer.FromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "verified OAuth ingress peer required")
	}
	tlsInfo, ok := p.AuthInfo.(credentials.TLSInfo)
	if !ok || len(tlsInfo.State.VerifiedChains) == 0 || len(tlsInfo.State.PeerCertificates) == 0 {
		return nil, status.Error(codes.Unauthenticated, "verified OAuth ingress peer required")
	}
	digest := sha256.Sum256(tlsInfo.State.PeerCertificates[0].Raw)
	return metadata.AppendToOutgoingContext(gatewayclient.WithProviderOAuth(ctx, token), ingress, hex.EncodeToString(digest[:])), nil
}
