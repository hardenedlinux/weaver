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
	"crypto/tls"
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
	"testing/quick"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/metering"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestProviderTerminalUsageIndependentIssuer(t *testing.T) {
	checkTerminalUsageIndependentIssuer(t, false)
}

func TestAnthropicTerminalUsageIndependentIssuer(t *testing.T) {
	checkTerminalUsageIndependentIssuer(t, true)
}

func checkTerminalUsageIndependentIssuer(t *testing.T, anthropic bool) {
	t.Helper()
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
			otherKey, _, err := ed25519.GenerateKey(rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			config, err := json.Marshal(map[string]any{
				"audience": "terminal-meter", "require_terminal_usage": true,
				"quotas": map[string]any{
					"families": map[string]string{"f": "key"},
					"keys":     map[string]any{"key": map[string]any{"principal": "alice", "limit": 4}},
					"users":    map[string]uint64{"alice": 4}, "tenants": map[string]uint64{"tenant": 4, "other": 4},
				},
				"tenants": map[string]any{
					"tenant": map[string]any{"issuer": "meter", "public_key": hex.EncodeToString(pub), "principals": []string{"alice"}, "rates": [4]uint64{1_000_000, 0, 0, 1_000_000}},
					"other":  map[string]any{"issuer": "other-meter", "public_key": hex.EncodeToString(otherKey), "principals": []string{"bob"}, "rates": [4]uint64{1_000_000}},
				},
			})
			if err != nil {
				t.Fatal(err)
			}
			profile := providerProfile()
			expected := []uint64{1, 2, 0, 1}
			if anthropic {
				profile.Protocol = v1.AnthropicMessagesSSE
				expected[2] = 1
			}
			f := fixtureWithProfileInvocation(t, func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "text/event-stream")
				if anthropic {
					emitAnthropic(w, complete)
					return
				}
				emitChunk(w, "hello", false)
				emitChunk(w, "", true)
				fmt.Fprint(w, "data: {\"id\":\"stream-1\",\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1,\"total_tokens\":4,\"prompt_tokens_details\":{\"cached_tokens\":2}}}\n\n")
				if complete {
					fmt.Fprint(w, "data: [DONE]\n\n")
				}
			}, false, serverBinary, nil, []string{"WEAVER_METERING=" + string(config)}, profile)
			ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
			defer cancel()
			rotate := func(tenant, issuer string, expected uint64, cert tls.Certificate, token string) *pb.MeterCredentialRotation {
				hash := sha256.Sum256([]byte(token))
				return &pb.MeterCredentialRotation{Tenant: tenant, Issuer: issuer, ExpectedEpoch: expected, Certificate: cert.Certificate[0], CredentialSha256: hex.EncodeToString(hash[:])}
			}
			publishMeter := func(r *pb.MeterCredentialRotation) (uint64, error) {
				out, err := f.admin.RPC.RotateMeterCredential(f.admin.Context(ctx), r)
				return out.GetEpoch(), err
			}
			dialMeter := func(cert tls.Certificate, token string) *gatewayclient.Client {
				t.Helper()
				client, err := gatewayclient.Dial(ctx, f.sourceAddress, token, &tls.Config{RootCAs: f.pki.root, Certificates: []tls.Certificate{cert}, ServerName: "localhost"})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { client.Connection.Close() })
				return client
			}
			cert := secondaryClient(t, f.pki)
			const token = "independent-meter-token"
			first := rotate("tenant", "meter", 0, cert, token)
			if epoch, err := publishMeter(first); err != nil || epoch != 1 {
				t.Fatalf("enrollment: %d %v", epoch, err)
			}
			meter := dialMeter(cert, token)
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
			if anthropic {
				changed := f.plan
				changed.Routes = slices.Clone(f.plan.Routes)
				for i, route := range changed.Routes {
					if route.Target == "primary" {
						changed.Routes[i].Endpoint = f.plan.Routes[len(f.plan.Routes)-1].Endpoint
					}
				}
				wrong, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{
					Plan: gatewayclient.Plan(changed), Encoding: pb.Encoding_PROTOBUF, BatchRows: 1, CatalogVersion: version,
				})
				if err == nil {
					_, err = wrong.Recv()
				}
				if status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 0 || f.backup.Load() != 0 {
					t.Fatalf("replacement Anthropic target sent: %v", err)
				}
			}
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
			newVersion, _ := publish(version, [4]uint64{2_000_000, 0, 0, 50_000})
			if !complete {
				f.stop(t)
				f.start(t)
				if _, err := meter.RPC.InspectTerminalUsage(meter.Context(ctx), operation); status.Code(err) != codes.PermissionDenied {
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
				if _, err := meter.RPC.ApplyMetering(meter.Context(ctx), &pb.MeteringReceipt{
					Audience: late.Audience, Tenant: late.Tenant, Issuer: late.Issuer, Application: late.Application, Family: late.Family, Node: late.Node,
					Origin: late.Origin, PlanDigest: late.PlanDigest, Target: late.Target, FormulaDigest: late.FormulaDigest,
					TerminalDigest: late.TerminalDigest, Tokens: late.Tokens[:], Signature: signature,
				}); status.Code(err) != codes.PermissionDenied {
					t.Fatalf("late signed usage released exposure: %v", err)
				}
				retry, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{
					Plan: gatewayclient.Plan(f.plan), Encoding: pb.Encoding_PROTOBUF, BatchRows: 1, CatalogVersion: newVersion,
				})
				if err == nil {
					_, err = retry.Recv()
				}
				if status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 1 || f.backup.Load() != 0 {
					t.Fatalf("interrupted provider was dispatched again: %v", err)
				}
				if r := inspect(t, f); r.GetState() != "unknown" || r.GetHeld() != 4 {
					t.Fatalf("unknown hold changed: %v", r)
				}
				return
			}
			observed, err := meter.RPC.InspectTerminalUsage(meter.Context(ctx), operation)
			if err != nil || !slices.Equal(observed.GetTokens(), expected) || observed.GetFormulaDigest() != oldFormula {
				t.Fatalf("normalized evidence: %v %v", observed, err)
			}
			if _, err := f.admin.RPC.InspectTerminalUsage(f.admin.Context(ctx), operation); status.Code(err) != codes.PermissionDenied {
				t.Fatalf("source read: %v", err)
			}
			if _, err := meter.RPC.InspectSourceAuthority(meter.Context(ctx), &pb.Empty{}); status.Code(err) != codes.Unauthenticated {
				t.Fatalf("meter source authority: %v", err)
			}
			otherCert := secondaryClient(t, f.pki)
			if _, err := publishMeter(rotate("other", "other-meter", 0, otherCert, "other-meter-token")); err != nil {
				t.Fatal(err)
			}
			other := dialMeter(otherCert, "other-meter-token")
			if err := quick.Check(func(onWrongTenant bool, wrongNode uint8) bool {
				request := proto.Clone(operation).(*pb.OperationKey)
				client := other
				if !onWrongTenant {
					client = meter
					request.Node = fmt.Sprintf("wrong-%d", wrongNode)
				}
				_, err := client.RPC.InspectTerminalUsage(client.Context(ctx), request)
				return status.Code(err) == codes.PermissionDenied
			}, &quick.Config{MaxCount: 12}); err != nil {
				t.Fatal(err)
			}
			issuer := metering.Issuer{Audience: "terminal-meter", Tenant: "tenant", ID: "meter", Key: key}
			loss := &meteringReplyLoss{GatewayClient: meter.RPC}
			if _, err := issuer.Settle(meter.Context(ctx), loss, operation); status.Code(err) != codes.Unavailable {
				t.Fatalf("settlement reply loss: %v", err)
			}
			if _, err := other.RPC.ApplyMetering(other.Context(ctx), loss.signed); status.Code(err) != codes.PermissionDenied {
				t.Fatalf("cross-tenant signed replay: %v", err)
			}
			if _, err := f.admin.RPC.ApplyMetering(f.admin.Context(ctx), loss.signed); status.Code(err) != codes.PermissionDenied {
				t.Fatalf("source signed replay: %v", err)
			}
			next := secondaryClient(t, f.pki)
			const nextToken = "independent-meter-next-token"
			rotation := rotate("tenant", "meter", 1, next, nextToken)
			lost := lostMeterRotation{GatewayClient: f.admin.RPC}
			if _, err := lost.RotateMeterCredential(f.admin.Context(ctx), rotation); status.Code(err) != codes.Unavailable {
				t.Fatalf("rotation loss: %v", err)
			}
			if epoch, err := publishMeter(rotation); err != nil || epoch != 2 {
				t.Fatalf("rotation recovery: %d %v", epoch, err)
			}
			if epoch, err := publishMeter(first); err != nil || epoch != 1 {
				t.Fatalf("historical replay: %d %v", epoch, err)
			}
			if _, err := issuer.Settle(meter.Context(ctx), meter.RPC, operation); status.Code(err) != codes.PermissionDenied {
				t.Fatalf("retired meter used before restart: %v", err)
			}
			f.stop(t)
			f.start(t)
			retired := dialMeter(cert, token)
			if _, err := retired.RPC.InspectTerminalUsage(retired.Context(ctx), operation); status.Code(err) != codes.PermissionDenied {
				t.Fatalf("retired meter used after restart: %v", err)
			}
			if _, err := retired.RPC.ApplyMetering(retired.Context(ctx), loss.signed); status.Code(err) != codes.PermissionDenied {
				t.Fatalf("retired meter signed replay: %v", err)
			}
			certKey, err := x509.MarshalPKCS8PrivateKey(next.PrivateKey)
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
				"WEAVER_METER_TLS_CERT=" + write("cert", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: next.Certificate[0]})),
				"WEAVER_METER_TLS_KEY=" + write("key", pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: certKey})),
				"WEAVER_METER_TLS_CA=" + write("ca", f.pki.ca),
				"WEAVER_METER_SIGNING_SEED=" + write("seed", []byte(hex.EncodeToString(key.Seed()))),
				"WEAVER_METER_AUDIENCE=terminal-meter", "WEAVER_METER_TENANT=tenant", "WEAVER_METER_ISSUER=meter",
				"WEAVER_METER_SOURCE_ADDR=" + f.sourceAddress, "WEAVER_METER_TOKEN=" + nextToken,
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

type lostMeterRotation struct{ pb.GatewayClient }

func (c lostMeterRotation) RotateMeterCredential(ctx context.Context, r *pb.MeterCredentialRotation, options ...grpc.CallOption) (*pb.MeterCredentialEpoch, error) {
	if _, err := c.GatewayClient.RotateMeterCredential(ctx, r, options...); err != nil {
		return nil, err
	}
	return nil, status.Error(codes.Unavailable, "meter rotation response lost")
}

func emitAnthropic(w http.ResponseWriter, complete bool) {
	frames := []struct{ kind, payload string }{
		{"message_start", `{"message":{"model":"model-a","role":"assistant","content":[],"stop_reason":null,"usage":{"input_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":1,"output_tokens":1}}}`},
		{"content_block_start", `{"index":0,"content_block":{"type":"text","text":""}}`},
		{"content_block_delta", `{"index":0,"delta":{"type":"text_delta","text":"hello"}}`},
		{"content_block_stop", `{"index":0}`},
		{"message_delta", `{"delta":{"stop_reason":null},"usage":{"output_tokens":1}}`},
		{"message_delta", `{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}`},
	}
	if complete {
		frames = append(frames, struct{ kind, payload string }{"message_stop", "{}"})
	}
	for _, frame := range frames {
		body := fmt.Sprintf("{\"type\":%q}", frame.kind)
		if frame.payload != "{}" {
			body = body[:len(body)-1] + "," + frame.payload[1:]
		}
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", frame.kind, body)
	}
}
