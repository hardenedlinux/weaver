// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func sourceTOMLCommand(t *testing.T, control *controlProcess, command *exec.Cmd, kubernetes ...string) *exec.Cmd {
	t.Helper()
	settings := make(map[string]string)
	environment := command.Env[:0]
	for _, value := range command.Env {
		name, text, _ := strings.Cut(value, "=")
		if strings.HasPrefix(name, "WEAVER_CONTROL_") {
			settings[name] = text
			continue
		}
		environment = append(environment, value)
	}
	const tokenEnv = "WEAVER_TEST_PREPARATION_TOKEN"
	var config strings.Builder
	config.WriteString("[source]\n")
	for _, field := range []struct{ key, env string }{
		{"producer", "WEAVER_CONTROL_PRODUCER"},
		{"file", "WEAVER_CONTROL_CONFIG"},
		{"address", "WEAVER_CONTROL_AUTHORITY_SOURCE_ADDRESS"},
		{"server_name", "WEAVER_CONTROL_AUTHORITY_SERVER_NAME"},
		{"ca", "WEAVER_CONTROL_AUTHORITY_CA"},
		{"certificate", "WEAVER_CONTROL_AUTHORITY_SOURCE_CERT"},
		{"key", "WEAVER_CONTROL_AUTHORITY_SOURCE_KEY"},
	} {
		value := settings[field.env]
		if (field.key == "producer" || field.key == "file") && (len(kubernetes) != 0 || value == "") {
			continue
		}
		if field.key == "ca" || field.key == "certificate" || field.key == "key" || field.key == "file" {
			var err error
			value, err = filepath.Rel(control.directory, value)
			if err != nil {
				t.Fatal(err)
			}
		}
		config.WriteString(field.key + " = " + strconv.Quote(value) + "\n")
	}
	config.WriteString("token_env = " + strconv.Quote(tokenEnv) + "\n")
	for _, section := range kubernetes {
		config.WriteString(section)
	}
	path := filepath.Join(control.directory, "weaver.toml")
	if err := os.WriteFile(path, []byte(config.String()), 0600); err != nil {
		t.Fatal(err)
	}
	command.Args = append(command.Args, "--config", path)
	command.Env = append(environment, tokenEnv+"="+settings["WEAVER_CONTROL_AUTHORITY_SOURCE_TOKEN"])
	return command
}

// File source preparation also retains exact plans for direct operation keys;
// it does not rely on the optional compiled single-provider retirement profile.
func TestProviderRustDirectFilePreparation(t *testing.T) {
	for _, format := range []string{"json", "yaml"} {
		t.Run(format, func(t *testing.T) { checkDirectFilePreparation(t, format) })
	}
}

func TestProviderRustDirectFilePreparationLostReplies(t *testing.T) {
	t.Run("staging", func(t *testing.T) {
		exerciseSourceReplyLoss(t, nil, true, controlPolicySources{}, serverBinary)
	})
	t.Run("publication", func(t *testing.T) {
		exerciseSourceReplyLoss(t, nil, false, controlPolicySources{}, serverBinary)
	})
}

func checkDirectFilePreparation(t *testing.T, format string) {
	t.Helper()
	f := newFixture(t, completeSSE, false)
	bundle := controlBundle(t, f)
	originalPolicy := bundle.Publication.Policy
	bundle.Publication.Policy += `
forbid(principal, action == Weaver::Action::"invokeProvider", resource) when { context.family == "control" && context.node == "next" };`
	control := newControlProcess(t, f, writeControlBundle(t, f, bundle, format))
	if format == "yaml" {
		ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
		command := sourceTOMLCommand(t, control, control.prepareCommand(ctx, serverBinary, "prepare"))
		output, err := command.CombinedOutput()
		cancel()
		if err != nil {
			t.Fatalf("source-only preparation from TOML file: %v: %s", err, output)
		}
	} else {
		control.prepareUsing(t, serverBinary, "prepare")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	run := func() error {
		stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{Plan: &pb.ProviderPlan{Family: "control", Node: "infer"}, Encoding: pb.Encoding_PROTOBUF, BatchRows: 1})
		if err != nil {
			return err
		}
		count := 0
		text := ""
		for {
			frame, err := stream.Recv()
			if err == io.EOF {
				if count != 5 || text != "hello world" {
					t.Fatalf("incomplete direct file stream: count=%d text=%q", count, text)
				}
				return nil
			}
			if err != nil {
				return err
			}
			count++
			text += frame.GetEvent().GetText()
		}
	}
	if err := run(); err != nil {
		t.Fatal(err)
	}
	if f.primary.Load() != 1 || control.child != nil {
		t.Fatal("direct file operation path", f.primary.Load())
	}
	deniedNext := func() {
		stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{Plan: &pb.ProviderPlan{Family: "control", Node: "next"}, Encoding: pb.Encoding_PROTOBUF, BatchRows: 1})
		if err == nil {
			_, err = stream.Recv()
		}
		if status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 1 {
			t.Fatalf("fixed projection used stale authority: %v", err)
		}
	}
	deniedNext() // Warm exact immutable data while Cedar denies execution.
	for index, policy := range []string{originalPolicy, bundle.Publication.Policy} {
		publication := bundle.Publication.Clone()
		revision := uint64(index + 1)
		publication.OperationID = "fixed-policy-" + strconv.Itoa(index)
		publication.ExpectedRevision = &revision
		publication.Fence = uint64(index + 2)
		publication.Policy = policy
		if _, err := f.admin.Publish(ctx, publication); err != nil {
			t.Fatal(err)
		}
		deniedNext() // Even newly allowing Cedar cannot rebase the old plan.
	}
	f.stop(t)
	f.start(t)
	if err := run(); err == nil || f.primary.Load() != 1 {
		t.Fatal("restart replayed file original", err)
	}
}

func TestProviderRustDirectFixedPlanSurvivesSourceHandoff(t *testing.T) {
	for _, mode := range []string{"warm", "cold", "restart"} {
		t.Run(mode, func(t *testing.T) {
			f := newFixture(t, completeSSE, false)
			bundle := controlBundle(t, f)
			newControlProcess(t, f, writeControlBundle(t, f, bundle, "json")).prepareUsing(t, serverBinary, "prepare")
			ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
			defer cancel()
			call := func(catalog string) error {
				stream, err := f.client.RPC.ExecuteProvider(f.client.Context(ctx), &pb.ProviderRequest{
					Plan: &pb.ProviderPlan{Family: "control", Node: "next"}, BatchRows: 1, CatalogVersion: catalog,
				})
				if err != nil {
					return err
				}
				for {
					frame, err := stream.Recv()
					if err == io.EOF {
						return nil
					}
					if err != nil {
						return err
					}
					if frame.GetEvent() == nil {
						t.Fatal("expected protobuf event")
					}
				}
			}
			if mode == "warm" {
				// Resolve the original while rejecting the caller's catalog precondition.
				if err := call(strings.Repeat("a", 64)); status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 0 {
					t.Fatalf("catalog precondition consumed fixed plan: %v", err)
				}
			}
			next := secondaryClient(t, f.pki)
			token := sha256.Sum256([]byte(f.admin.Token))
			rotation := v1.SourceRotation{OperationID: "fixed-source-handoff", ExpectedEpoch: 0, NextCertificate: next.Certificate[0], NextCredentialSHA256: hex.EncodeToString(token[:])}
			if receipt, err := f.admin.RotateSource(ctx, rotation); err != nil || receipt.GetAuthority().GetEpoch() != 1 {
				t.Fatalf("source handoff: %v %v", receipt, err)
			}
			if _, err := f.admin.SourceAuthority(ctx); status.Code(err) != codes.PermissionDenied {
				t.Fatalf("retired source retained mutation identity: %v", err)
			}
			if mode == "restart" {
				restartWithSourceCertificate(t, f, next)
			}
			if err := call(""); err != nil || f.primary.Load() != 1 || f.backup.Load() != 0 {
				t.Fatalf("fixed publication changed after source handoff: sends=%d error=%v", f.primary.Load(), err)
			}
		})
	}
}
