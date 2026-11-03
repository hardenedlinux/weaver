// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package gatewayclient

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"google.golang.org/grpc"
	"google.golang.org/grpc/backoff"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/stats"
	"google.golang.org/grpc/test/bufconn"
	"math/rand"
	"net"
	"sync/atomic"
	"testing"
	"testing/quick"
	"time"
)

func TestConnectionSetupRetainsCallerDeadlineAndCancellation(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	// The kernel accepts TCP, but no peer completes TLS or can receive an RPC.
	security := &tls.Config{RootCAs: x509.NewCertPool(), Certificates: []tls.Certificate{{}}}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	client, err := Dial(ctx, listener.Addr().String(), "test-credential", security)
	if client != nil || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("connection attempt escaped caller deadline: client=%v error=%v", client, err)
	}
	cancelled, stop := context.WithCancel(context.Background())
	stop()
	client, err = Dial(cancelled, listener.Addr().String(), "test-credential", security)
	if client != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled setup created a client: client=%v error=%v", client, err)
	}
}

func TestInitialConnectionBudgetDoesNotAuthorizeOrRetryRPCs(t *testing.T) {
	property := func(raw uint8) bool {
		failures := uint64(1 + raw%3)
		listener := bufconn.Listen(1 << 20)
		calls := &initialRPCObservation{}
		server := grpc.NewServer(grpc.StatsHandler(calls))
		finished := make(chan error, 1)
		go func() { finished <- server.Serve(listener) }()
		defer func() { server.Stop(); listener.Close(); <-finished }()
		connect := func() (*grpc.ClientConn, *atomic.Uint64, error) {
			attempts := new(atomic.Uint64)
			config := backoff.DefaultConfig
			config.BaseDelay = time.Second
			config.MaxDelay = time.Second
			connection, err := grpc.NewClient("passthrough:///delayed", grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithDisableRetry(), grpc.WithConnectParams(grpc.ConnectParams{Backoff: config, MinConnectTimeout: time.Second}), grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
				if attempts.Add(1) <= failures {
					return nil, fmt.Errorf("controlled initial connection refusal")
				}
				return listener.DialContext(ctx)
			}))
			return connection, attempts, err
		}
		control, _, err := connect()
		if err != nil {
			t.Log(err)
			return false
		}
		contextA, cancelA := context.WithTimeout(context.Background(), 350*time.Millisecond)
		control.Connect()
		for contextA.Err() == nil && control.GetState() != connectivity.Ready {
			control.WaitForStateChange(contextA, control.GetState())
		}
		refused := contextA.Err() != nil && control.GetState() != connectivity.Ready
		cancelA()
		control.Close()
		candidate, attempts, err := connect()
		if err != nil {
			t.Log(err)
			return false
		}
		defer candidate.Close()
		contextB, cancelB := context.WithTimeout(context.Background(), 350*time.Millisecond)
		defer cancelB()
		candidate.Connect()
		err = awaitReady(contextB, candidate, 20*time.Millisecond)
		return refused && err == nil && candidate.GetState() == connectivity.Ready && attempts.Load() == failures+1 && calls.count.Load() == 0
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 8, Rand: rand.New(rand.NewSource(293))}); err != nil {
		t.Fatal(err)
	}
}

type initialRPCObservation struct{ count atomic.Uint64 }

func (s *initialRPCObservation) TagRPC(ctx context.Context, _ *stats.RPCTagInfo) context.Context {
	s.count.Add(1)
	return ctx
}
func (*initialRPCObservation) HandleRPC(context.Context, stats.RPCStats) {}
func (*initialRPCObservation) TagConn(ctx context.Context, _ *stats.ConnTagInfo) context.Context {
	return ctx
}
func (*initialRPCObservation) HandleConn(context.Context, stats.ConnStats) {}
