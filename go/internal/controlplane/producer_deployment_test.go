// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Exercise the actual deployment entry, not an injected Bootstrap replacement.
func exerciseProducerDeployment(t *testing.T, ctx context.Context, directory string, plan v1.ProviderPlan) {
	t.Helper()
	reservation, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := reservation.Addr().String()
	if err := reservation.Close(); err != nil {
		t.Fatal(err)
	}
	identity, err := tls.LoadX509KeyPair(filepath.Join(directory, "operation.pem"), filepath.Join(directory, "operation.key"))
	if err != nil {
		t.Fatal(err)
	}
	leaf := sha256.Sum256(identity.Certificate[0])
	token := sha256.Sum256([]byte("control-token"))
	values := map[string]string{
		"PRODUCER": "approved-AA", "LISTEN": address,
		"SERVER_CERT": filepath.Join(directory, "server.pem"), "SERVER_KEY": filepath.Join(directory, "server.key"),
		"CLIENT_CA": filepath.Join(directory, "ca.pem"), "PEER_SHA256": hex.EncodeToString(leaf[:]), "TOKEN_SHA256": hex.EncodeToString(token[:]),
		"AUTHORITY_CA": filepath.Join(directory, "ca.pem"), "AUTHORITY_OPERATION_CERT": filepath.Join(directory, "operation.pem"), "AUTHORITY_OPERATION_KEY": filepath.Join(directory, "operation.key"),
		"AUTHORITY_SOURCE_CERT": filepath.Join(directory, "source.pem"), "AUTHORITY_SOURCE_KEY": filepath.Join(directory, "source.key"),
		"AUTHORITY_OPERATION_TOKEN": "operation-token", "AUTHORITY_SOURCE_TOKEN": "source-token",
		"AUTHORITY_OPERATION_ADDRESS": os.Getenv("WEAVER_TEST_APPROVED_OPERATION"), "AUTHORITY_SOURCE_ADDRESS": os.Getenv("WEAVER_TEST_APPROVED_SOURCE"), "AUTHORITY_SERVER_NAME": "localhost",
		"SCHEME_COMPILER": filepath.Join(directory, "compiler-must-not-run"),
	}
	for key, value := range values {
		t.Setenv("WEAVER_CONTROL_"+key, value)
	}
	t.Setenv("WEAVER_CONTROL_CONFIG", "")
	if err := os.Unsetenv("WEAVER_CONTROL_CONFIG"); err != nil {
		t.Fatal(err)
	}
	run, stop := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() { done <- RunFromEnv(run) }()
	defer func() {
		stop()
		select {
		case err := <-done:
			if err != nil {
				t.Error("deployment natural drain", err)
			}
		case <-time.After(3 * time.Second):
			t.Error("deployment did not drain naturally")
		}
	}()
	ca, err := os.ReadFile(filepath.Join(directory, "ca.pem"))
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		t.Fatal("CA missing")
	}
	connect, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	client, err := gatewayclient.Dial(connect, address, "control-token", &tls.Config{RootCAs: roots, Certificates: []tls.Certificate{identity}, ServerName: "localhost"})
	if err != nil {
		t.Fatal("producer deployment did not activate", err)
	}
	defer client.Connection.Close()
	_, err = client.RPC.CompileSource(client.Context(ctx), &pb.ProducerRequest{Producer: "approved-AA"})
	if status.Code(err) != codes.Unimplemented {
		t.Fatal("operation frontend exposed privileged compilation", err)
	}
	_, err = client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { t.Error("forbidden deployment output"); return nil })
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatal("deployment bypassed original final Policy", err)
	}
	t.Log("actual Go deployment selected authenticated producer and naturally drained without a Scheme process")
}
