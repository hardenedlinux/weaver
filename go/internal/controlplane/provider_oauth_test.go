// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"strings"
	"testing"

	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
)

func FuzzProviderOAuthRelayBindsVerifiedPeer(f *testing.F) {
	for _, flags := range []uint8{0, 1, 3, 5} {
		f.Add(flags, strings.Repeat("a", 32), []byte("certificate"))
	}
	f.Fuzz(func(t *testing.T, flags uint8, token string, certificate []byte) {
		const tokenHeader = "weaver-provider-oauth"
		const ingressHeader = "weaver-provider-oauth-ingress-cert"
		g := &Gateway{oauthRelay: true}
		md := metadata.Pairs(tokenHeader, "Bearer "+token)
		if flags&2 != 0 {
			md.Append(ingressHeader, "caller-supplied")
		}
		if flags&4 != 0 {
			md.Append(tokenHeader, "Bearer "+token)
		}
		cert := &x509.Certificate{Raw: certificate}
		state := tls.ConnectionState{PeerCertificates: []*x509.Certificate{cert}}
		if flags&1 != 0 {
			state.VerifiedChains = [][]*x509.Certificate{{cert}}
		}
		ctx := metadata.NewIncomingContext(t.Context(), md)
		ctx = peer.NewContext(ctx, &peer.Peer{AuthInfo: credentials.TLSInfo{State: state}})
		result, err := g.providerContext(ctx)
		ascii := strings.IndexFunc(token, func(r rune) bool { return r < 33 || r > 126 }) == -1
		want := flags&7 == 1 && len(token) >= 32 && len(token) <= 256 && ascii
		if (err == nil) != want {
			t.Fatalf("credential admission differed from relay contract: %v", err)
		}
		if !want {
			return
		}
		actual, _ := metadata.FromOutgoingContext(result)
		digest := sha256.Sum256(certificate)
		if got := actual.Get(ingressHeader); len(got) != 1 || got[0] != hex.EncodeToString(digest[:]) {
			t.Fatal("relay did not forward exactly the verified peer digest")
		}
		if got := actual.Get(tokenHeader); len(got) != 1 || got[0] != "Bearer "+token {
			t.Fatal("relay did not preserve exactly one credential")
		}
	})
}
