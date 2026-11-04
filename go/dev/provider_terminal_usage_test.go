// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/metering"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestProviderTerminalUsageIndependentIssuer(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	binary := filepath.Join(t.TempDir(), "weaver-meter")
	build := exec.Command(filepath.Join(runtime.GOROOT(), "bin/go"), "-C", "go", "build", "-o", binary, "./cmd/weaver-meter")
	build.Dir = root(t)
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("meter build: %v: %s", err, output)
	}
	for _, complete := range []bool{true, false} {
		t.Run(fmt.Sprint(complete), func(t *testing.T) {
			pub, key, err := ed25519.GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			config, err := json.Marshal(map[string]any{
				"audience": "terminal-meter", "require_terminal_usage": true,
				"quotas": map[string]any{
					"families": map[string]string{"f": "key"},
					"keys":     map[string]any{"key": map[string]any{"principal": "alice", "limit": 4}},
					"users":    map[string]uint64{"alice": 4}, "tenants": map[string]uint64{"tenant": 4},
				},
				"tenants": map[string]any{"tenant": map[string]any{
					"issuer": "meter", "public_key": hex.EncodeToString(pub), "principals": []string{"alice"},
					"rates": [4]uint64{1_000_000, 0, 0, 1_000_000},
				}},
			})
			if err != nil {
				t.Fatal(err)
			}
			f := fixtureWithInvocation(t, func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				emitChunk(w, "hello", false)
				emitChunk(w, "", true)
				fmt.Fprint(w, "data: {\"id\":\"stream-1\",\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1,\"total_tokens\":4,\"prompt_tokens_details\":{\"cached_tokens\":2}}}\n\n")
				if complete {
					fmt.Fprint(w, "data: [DONE]\n\n")
				}
			}, false, serverBinary, nil, []string{"WEAVER_METERING=" + string(config)})
			ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
			defer cancel()
			operation := &pb.OperationKey{Family: f.plan.Family, Node: f.plan.Node}
			digest, err := f.plan.Digest()
			if err != nil {
				t.Fatal(err)
			}
			publish := func(parent string, rates [4]uint64) (string, string) {
				t.Helper()
				formula, err := v1.MeteringFormulaDigest(rates)
				if err != nil {
					t.Fatal(err)
				}
				record, err := json.Marshal(map[string]any{"parent": parent, "entries": map[string]any{digest: map[string]any{
					"module": "standard", "capabilities": []string{}, "latency_millis": 10, "user_rates": rates,
					"quote": map[string]any{"version": "purchase", "tenant": "tenant", "formula_digest": formula,
						"procurement_rates": [4]uint64{100_000}, "token_bounds": [4]uint64{1, 2, 0, 32}},
				}}})
				if err != nil {
					t.Fatal(err)
				}
				out, err := f.admin.RPC.PublishProviderCatalog(f.admin.Context(ctx), &pb.ProviderCatalogChange{Record: record})
				if err != nil {
					t.Fatal(err)
				}
				return out.Version, formula
			}
			version, oldFormula := publish("", [4]uint64{1_000_000, 0, 0, 50_000})
			stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{
				Plan: gatewayclient.Plan(f.plan), Encoding: pb.Encoding_PROTOBUF, BatchRows: 1, CatalogVersion: version,
			})
			if err == nil {
				for err == nil {
					_, err = stream.Recv()
				}
				if err == io.EOF {
					err = nil
				}
			}
			if (err == nil) != complete {
				t.Fatalf("execution: %v", err)
			}
			publish(version, [4]uint64{2_000_000, 0, 0, 50_000})
			if !complete {
				f.stop(t)
				f.start(t)
				if _, err := f.admin.RPC.InspectTerminalUsage(f.admin.Context(ctx), operation); status.Code(err) != codes.PermissionDenied {
					t.Fatalf("late nonterminal usage became signable: %v", err)
				}
				r := inspect(t, f)
				late := v1.TerminalUsage{Audience: "terminal-meter", Tenant: "tenant", Issuer: "meter", Application: "late", Family: operation.Family, Node: operation.Node,
					Origin: operation.Family, PlanDigest: digest, Target: r.GetTarget(), FormulaDigest: oldFormula,
					TerminalDigest: strings.Repeat("a", 64), Tokens: [4]uint64{1, 2, 0, 1}}
				signature, err := late.Sign(key)
				if err != nil {
					t.Fatal(err)
				}
				if _, err := f.admin.RPC.ApplyMetering(f.admin.Context(ctx), &pb.MeteringReceipt{
					Audience: late.Audience, Tenant: late.Tenant, Issuer: late.Issuer, Application: late.Application, Family: late.Family, Node: late.Node,
					Origin: late.Origin, PlanDigest: late.PlanDigest, Target: late.Target, FormulaDigest: late.FormulaDigest,
					TerminalDigest: late.TerminalDigest, Tokens: late.Tokens[:], Signature: signature,
				}); status.Code(err) != codes.PermissionDenied {
					t.Fatalf("late signed usage released exposure: %v", err)
				}
				if r := inspect(t, f); r.GetState() != "unknown" || r.GetHeld() != 4 {
					t.Fatalf("unknown hold changed: %v", r)
				}
				return
			}
			observed, err := f.admin.RPC.InspectTerminalUsage(f.admin.Context(ctx), operation)
			if err != nil || !slices.Equal(observed.GetTokens(), []uint64{1, 2, 0, 1}) || observed.GetFormulaDigest() != oldFormula {
				t.Fatalf("normalized evidence: %v %v", observed, err)
			}
			issuer := metering.Issuer{Audience: "terminal-meter", Tenant: "tenant", ID: "meter", Key: key}
			loss := &meteringReplyLoss{GatewayClient: f.admin.RPC}
			if _, err := issuer.Settle(f.admin.Context(ctx), loss, operation); status.Code(err) != codes.Unavailable {
				t.Fatalf("settlement reply loss: %v", err)
			}
			f.stop(t)
			f.start(t)
			certKey, err := x509.MarshalPKCS8PrivateKey(f.pki.source.PrivateKey)
			if err != nil {
				t.Fatal(err)
			}
			write := func(name string, bytes []byte) string {
				t.Helper()
				path := filepath.Join(t.TempDir(), name)
				if err := os.WriteFile(path, bytes, 0600); err != nil {
					t.Fatal(err)
				}
				return path
			}
			settings := []string{
				"WEAVER_METER_TLS_CERT=" + write("cert", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: f.pki.source.Certificate[0]})),
				"WEAVER_METER_TLS_KEY=" + write("key", pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: certKey})),
				"WEAVER_METER_TLS_CA=" + write("ca", f.pki.ca),
				"WEAVER_METER_SIGNING_SEED=" + write("seed", []byte(hex.EncodeToString(key.Seed()))),
				"WEAVER_METER_AUDIENCE=terminal-meter", "WEAVER_METER_TENANT=tenant", "WEAVER_METER_ISSUER=meter",
				"WEAVER_METER_SOURCE_ADDR=" + f.sourceAddress, "WEAVER_METER_SOURCE_TOKEN=" + f.admin.Token,
				"WEAVER_METER_TLS_SERVER_NAME=localhost",
			}
			for range 2 {
				cmd := exec.CommandContext(ctx, binary, operation.Family, operation.Node)
				cmd.Env = append(os.Environ(), settings...)
				data, err := cmd.CombinedOutput()
				if err != nil {
					t.Fatalf("restarted meter: %v: %s", err, data)
				}
				var replay pb.MeteringApplication
				if err := json.Unmarshal(data, &replay); err != nil || !proto.Equal(&replay, loss.committed) {
					t.Fatalf("settlement replay: %v: %s", err, data)
				}
			}
			if loss.committed.GetCharged() != 2 || loss.committed.GetReleased() != 2 || inspect(t, f).GetHeld() != 2 || f.primary.Load() != 1 {
				t.Fatalf("unexpected retained charge: %v", loss.committed)
			}
		})
	}
}
