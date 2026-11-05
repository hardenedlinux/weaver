// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"sync"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestProviderOAuthRevocationGuardsReleaseAndRecovery(t *testing.T) {
	public, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	const issuer, subject, client, audience = "issuer", "alice", "operation-client", "weaver"
	deployment, err := json.Marshal(map[string]string{
		"issuer": issuer, "subject": subject, "client": client, "audience": audience,
		"public_key": hex.EncodeToString(public),
	})
	if err != nil {
		t.Fatal(err)
	}
	entered, release := make(chan struct{}), make(chan struct{})
	var seen, finish sync.Once
	unblock := func() { finish.Do(func() { close(release) }) }
	defer unblock()
	f := fixtureWithInvocation(t, func(w http.ResponseWriter, r *http.Request) {
		seen.Do(func() { close(entered) })
		select {
		case <-release:
			completeSSE(w, r)
		case <-r.Context().Done():
		}
	}, false, serverBinary, nil, []string{"WEAVER_PROVIDER_OAUTH=" + string(deployment), "WEAVER_STORAGE_JOURNAL=mvcc"})
	ctx, cancel := context.WithTimeout(t.Context(), 18*time.Second)
	defer cancel()
	hash := func(data []byte) string {
		sum := sha256.Sum256(data)
		return hex.EncodeToString(sum[:])
	}
	peer := hash(f.pki.client.Certificate[0])
	makeGrant := func(token, cert string, start, expires uint64, scopes ...string) *pb.ProviderOAuthChange {
		grant := &pb.ProviderOAuthGrant{Issuer: issuer, Subject: subject, Client: client, Audience: audience,
			Scopes: scopes, TokenHash: hash([]byte(token)), CertificateSha256: cert, NotBefore: start, ExpiresAt: expires}
		body, err := json.Marshal([]any{"weaver.provider-oauth.grant.v1", issuer, subject, client, audience,
			scopes, grant.TokenHash, cert, start, expires})
		if err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(body)
		grant.Signature = hex.EncodeToString(ed25519.Sign(key, digest[:]))
		return &pb.ProviderOAuthChange{Action: &pb.ProviderOAuthChange_Grant{Grant: grant}}
	}
	change := func(change *pb.ProviderOAuthChange) error {
		_, err := f.admin.RPC.ChangeProviderOAuth(f.admin.Context(ctx), change)
		return err
	}
	publish := func(changeRequest *pb.ProviderOAuthChange) {
		t.Helper()
		if err := change(changeRequest); err != nil {
			t.Fatal(err)
		}
	}
	execute := func(ctx context.Context, token string, onEvent func(*pb.Event) error) (*pb.ProviderReceipt, error) {
		return f.client.Execute(gatewayclient.WithProviderOAuth(ctx, token), f.plan, pb.Encoding_PROTOBUF, 1, onEvent)
	}
	noEvent := func(*pb.Event) error {
		t.Error("denied operation released an event")
		return nil
	}
	now := uint64(time.Now().Unix())
	const op = "synthetic-provider-operation-token-0001"
	const observe = "synthetic-provider-observation-token-02"
	const wrong = "synthetic-provider-wrong-peer-token-003"
	const expired = "synthetic-provider-expired-token-00004"
	const next = "synthetic-provider-renewed-token-00005"

	if _, err := f.client.Execute(ctx, f.plan, pb.Encoding_PROTOBUF, 1, noEvent); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("missing OAuth proof: %v", err)
	}
	good := makeGrant(op, peer, now-1, now+120, "provider:execute")
	if _, err := f.client.RPC.ChangeProviderOAuth(f.client.Context(ctx), good); err == nil {
		t.Fatal("operation ingress published an issuer grant")
	}
	forged := makeGrant(op, peer, now-1, now+120, "provider:execute")
	forged.GetGrant().Scopes = append(forged.GetGrant().Scopes, "provider:inspect")
	if err := change(forged); err == nil {
		t.Fatal("altered signed evidence accepted")
	}
	publish(makeGrant(wrong, hash([]byte("wrong peer")), now-1, now+120, "provider:execute"))
	publish(makeGrant(expired, peer, now-120, now-60, "provider:execute"))
	publish(makeGrant(observe, peer, now-1, now+120, "provider:inspect"))
	for _, token := range []string{wrong, expired, observe} {
		if _, err := execute(ctx, token, noEvent); err == nil {
			t.Fatal("invalid sender, scope or time reached execution")
		}
	}
	if f.primary.Load() != 0 {
		t.Fatal("invalid grant reached provider")
	}
	publish(good)
	publish(good)
	if _, err := f.client.RPC.Inspect(gatewayclient.WithProviderOAuth(ctx, observe), &pb.OperationKey{Family: f.plan.Family, Node: f.plan.Node}); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("OAuth without the existing operation credential: %v", err)
	}
	worker := make(chan error, 1)
	go func() {
		_, err := execute(ctx, op, noEvent)
		worker <- err
	}()
	select {
	case <-entered:
	case err := <-worker:
		t.Fatalf("operation ended before the provider was reached: %v", err)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	revoke := &pb.ProviderOAuthChange{Action: &pb.ProviderOAuthChange_RevokeTokenHash{RevokeTokenHash: good.GetGrant().TokenHash}}
	publish(revoke)
	publish(revoke)
	unblock()
	if err := <-worker; err == nil {
		t.Fatal("response release after revocation succeeded")
	}
	inspect := func() {
		t.Helper()
		result, err := f.client.RPC.Inspect(f.client.Context(gatewayclient.WithProviderOAuth(ctx, observe)),
			&pb.OperationKey{Family: f.plan.Family, Node: f.plan.Node})
		if err != nil || result.GetState() != "unknown" || result.GetHeld() != 4 || result.GetEvents() != 0 {
			t.Fatalf("revoked effect lost its original hold or released output: %v, %v", result, err)
		}
	}
	inspect()
	f.stop(t)
	f.start(t)
	if err := change(good); err == nil {
		t.Fatal("replayed publication reopened a revoked grant")
	}
	publish(makeGrant(next, peer, now-1, now+120, "provider:execute"))
	for _, token := range []string{op, next} {
		if _, err := execute(ctx, token, noEvent); err == nil {
			t.Fatal("recovered or renewed grant reopened the original")
		}
	}
	inspect()
	if f.primary.Load() != 1 {
		t.Fatalf("provider observed %d requests for one original", f.primary.Load())
	}
}
