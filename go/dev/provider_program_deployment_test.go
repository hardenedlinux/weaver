// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && schemeintegration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type configuredAuthority struct {
	Epoch    uint64            `json:"epoch"`
	Identity v1.SourceIdentity `json:"identity"`
}
type configuredProducer struct {
	Name      string              `json:"name"`
	Authority configuredAuthority `json:"authority"`
	Original  config.Bundle       `json:"original"`
}
type configuredCatalog struct {
	Producers []configuredProducer `json:"producers"`
}

func configuredCatalogPath(t testing.TB, f *fixture, bundle config.Bundle) string {
	t.Helper()
	// These values bind eligibility; actual mTLS/credential authentication
	// and the ledger's source floor remain mandatory at each source RPC.
	cert, err := x509.ParseCertificate(f.pki.source.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	leaf, key, credential := sha256.Sum256(cert.Raw), sha256.Sum256(cert.RawSubjectPublicKeyInfo), sha256.Sum256([]byte(adminToken))
	identity := v1.SourceIdentity{CertificateSHA256: hex.EncodeToString(leaf[:]), PublicKeySHA256: hex.EncodeToString(key[:]), CredentialSHA256: hex.EncodeToString(credential[:])}
	data, err := json.Marshal(configuredCatalog{Producers: []configuredProducer{{Name: "approved-control", Authority: configuredAuthority{Identity: identity}, Original: bundle}}})
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(f.directory, "approved-catalog.json")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestProviderControlCompiledProgramRevocationAndRestart(t *testing.T) {
	exerciseControlPolicies(t, "json", nil, compiledControlSources(false))
}

func TestProviderControlCompiledProgramSharedBudgetRejectsConcurrentSendAndSDKRetry(t *testing.T) {
	exerciseControlSharedBudgetPolicies(t, nil, compiledControlSources(false))
}

func TestProviderControlCompiledPreflightCannotAuthorize(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	bundle := controlBundle(t, f)
	bundle.Publication.Policy = "forbid(principal,action,resource);"
	policy := compiledControlSources(false)
	policy.configure(t, f, bundle)
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.useProducer(policy.producer)
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	_, err := c.client.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1,
		func(*pb.Event) error { t.Error("inert preflight authorized an effect"); return nil })
	if status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("compiled Scheme/Cedar preflight bypassed final Policy", err)
	}
}

func TestProviderControlCompiledAssetsRevocationAndRestart(t *testing.T) {
	exerciseControlPolicies(t, "json", nil, compiledControlSources(true))
}

func compiledControlSources(assets bool) controlPolicySources {
	return controlPolicySources{producer: "approved-control", configure: func(t *testing.T, f *fixture, bundle config.Bundle) {
		path := configuredCatalogPath(t, f, bundle)
		f.stop(t)
		f.env = append(f.env, "WEAVER_GOVERNANCE_CATALOG="+path)
		if assets {
			assetRoot := filepath.Join(f.directory, "governance-assets")
			if err := os.Mkdir(assetRoot, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(assetRoot, "policy.cedar"), []byte(bundle.Publication.Policy), 0600); err != nil {
				t.Fatal(err)
			}
			f.env = append(f.env, "WEAVER_TEST_GOVERNANCE_ASSET_ROOT="+assetRoot)
		}
		f.start(t)
	}}
}

func TestProviderControlCompiledAssetsPublicationReplyLossAndRestart(t *testing.T) {
	exerciseControlSourceReplyLoss(t, nil, false, compiledControlSources(true))
}

func TestProviderControlCompiledAssetsStagingReplyLossAndRestart(t *testing.T) {
	exerciseControlSourceReplyLoss(t, nil, true, compiledControlSources(true))
}

func TestProviderControlCompiledAssetsPartialRequestAndRestart(t *testing.T) {
	f := newFixture(t, partialRequestDisconnect, true)
	bundle := controlBundle(t, f)
	policy := compiledControlSources(true)
	policy.configure(t, f, bundle)
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.useProducer(policy.producer)
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	plan := bundle.Plans[0]
	if _, err := c.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("partial request accepted as complete")
	}
	key := &pb.OperationKey{Family: plan.Family, Node: plan.Node}
	before, err := c.client.RPC.Inspect(c.client.Context(ctx), key)
	if err != nil || before.GetState() != "unknown" || before.GetHeld() != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatal("partial execution lost its original hold", before, err)
	}
	cancel()
	c.stop(t)
	f.stop(t)
	f.start(t)
	c.start(t)
	ctx, cancel = context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if _, err := c.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("restart or SDK retry reopened the consumed claim")
	}
	after, err := c.client.RPC.Inspect(c.client.Context(ctx), key)
	if err != nil || !proto.Equal(before, after) || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatal("restart duplicated the send or released unknown budget", after, err)
	}
}

func TestProviderControlCompiledProgramRequiresRealInstallation(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	path := configuredCatalogPath(t, f, controlBundle(t, f))
	f.stop(t)
	// The application is linked and initialized, but deliberately does not
	// register its producer. No mock readiness response or forced exit is used.
	cmd := exec.Command(serverBinary)
	cmd.Env = append(append(os.Environ(), f.env...), "WEAVER_GOVERNANCE_CATALOG="+path, "WEAVER_TEST_SKIP_PROGRAM_INSTALL=1")
	started := time.Now()
	output, err := cmd.CombinedOutput()
	if err == nil || time.Since(started) > 3*time.Second {
		t.Fatalf("missing installation did not refuse naturally within startup gate: %v %s", err, output)
	}
	if !strings.Contains(string(output), "governance initialization failed") || strings.Contains(string(output), "stage=listeners-bound") {
		t.Fatalf("uninstalled application reached serving or failed elsewhere: %s", output)
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("initialization refusal sent provider traffic")
	}
}
