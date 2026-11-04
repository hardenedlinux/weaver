// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"encoding/json"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestAnthropicWifTargetAndUnauthorizedNeverRedispatch(t *testing.T) {
	for _, test := range []struct {
		name  string
		wif   bool
		calls int64
	}{{"401", false, 1}, {"wrong-wif-target", true, 0}} {
		t.Run(test.name, func(t *testing.T) {
			profile := providerProfile()
			profile.Protocol = v1.AnthropicMessagesSSE
			var env []string
			if test.wif {
				value, err := json.Marshal(map[string]any{"primary": map[string]string{
					"assertion_file":     filepath.Join(t.TempDir(), "never-read"),
					"federation_rule_id": "fdrl_fixture", "organization_id": "00000000-0000-0000-0000-000000000000",
					"service_account_id": "svac_fixture", "workspace_id": "wrkspc_fixture",
				}})
				if err != nil {
					t.Fatal(err)
				}
				env = []string{"WEAVER_PROVIDER_CREDENTIAL_ENVS={}", "WEAVER_ANTHROPIC_WIF=" + string(value)}
			}
			f := fixtureWithProfileInvocation(t, func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusUnauthorized)
			}, false, serverBinary, nil, env, profile)
			ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
			defer cancel()
			invoke := func() error {
				stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{
					Plan: gatewayclient.Plan(f.plan), Encoding: pb.Encoding_PROTOBUF, BatchRows: 1,
				})
				if err == nil {
					_, err = stream.Recv()
				}
				return err
			}
			if err := invoke(); status.Code(err) != codes.FailedPrecondition {
				t.Fatalf("first invocation: %v", err)
			}
			f.stop(t)
			f.start(t)
			if err := invoke(); status.Code(err) != codes.FailedPrecondition {
				t.Fatalf("replayed invocation: %v", err)
			}
			r := inspect(t, f)
			if f.primary.Load() != test.calls || f.backup.Load() != 0 || r.GetState() != "unknown" || r.GetHeld() != 4 {
				t.Fatalf("dispatch or exposure changed: primary=%d backup=%d receipt=%v", f.primary.Load(), f.backup.Load(), r)
			}
		})
	}
}
