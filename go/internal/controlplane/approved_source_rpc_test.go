// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package controlplane

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type captureCompiledRPC struct {
	pb.GatewayClient
	result *pb.CompiledSource
	calls  int
}

func (c *captureCompiledRPC) CompileSource(ctx context.Context, p *pb.ProducerRequest, options ...grpc.CallOption) (*pb.CompiledSource, error) {
	c.calls++
	result, err := c.GatewayClient.CompileSource(ctx, p, options...)
	c.result = result
	return result, err
}

// The real Rust/SDK owner supplies ephemeral authenticated endpoints. A normal
// package run cannot count an absent external fixture as SDK acceptance.
func TestApprovedSourceMTLSBootstrap(t *testing.T) {
	sourceAddress := os.Getenv("WEAVER_TEST_APPROVED_SOURCE")
	if sourceAddress == "" {
		t.Skip("requires the actual Rust SDK/mTLS qualification owner")
	}
	directory := os.Getenv("WEAVER_TEST_APPROVED_PKI")
	ca, err := os.ReadFile(filepath.Join(directory, "ca.pem"))
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		t.Fatal("test CA missing")
	}
	dial := func(address, role, token string) *gatewayclient.Client {
		pair, err := tls.LoadX509KeyPair(filepath.Join(directory, role+".pem"), filepath.Join(directory, role+".key"))
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		client, err := gatewayclient.Dial(ctx, address, token, &tls.Config{RootCAs: roots, Certificates: []tls.Certificate{pair}, ServerName: "localhost"})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { client.Connection.Close() })
		return client
	}
	source := dial(sourceAddress, "source", "source-token")
	owner := dial(os.Getenv("WEAVER_TEST_APPROVED_OPERATION"), "operation", "operation-token")
	captured := &captureCompiledRPC{GatewayClient: source.RPC}
	source.RPC = captured
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	gateway, err := BootstrapProducer(ctx, source, owner, "approved-AA")
	if err != nil || gateway == nil || captured.calls != 1 {
		t.Fatal("approved source bootstrap failed", err, captured.calls)
	}
	bundle, err := compiledBundle(captured.result.Artifact)
	if err != nil {
		t.Fatal(err)
	}
	_, err = owner.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { t.Fatal("forbidden provider output"); return nil })
	// Execution errors deliberately retain uncertainty through the public RPC.
	// Inspect also conservatively maps missing state to FailedPrecondition.
	// Neither error proves absence: the owning Rust fixture independently opens
	// the durable ledger and checks no admission, then runs a Permit control.
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatal("published forbid did not constrain final Rust execution", err)
	}
	_, err = owner.RPC.Inspect(owner.Context(ctx), &pb.OperationKey{Family: "f", Node: "infer"})
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatal("unexpected forbidden operation inspection", err)
	}
	exerciseProducerDeployment(t, ctx, directory, bundle.Plans[0])
	t.Log("Scheme SDK -> authenticated CompileSource -> typed Go Bootstrap -> Rust final Policy denial")
}
