// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/json"
	"fmt"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/controlplane"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// JSON configuration admission, authority CAS, Routing and Rust final stream.
// This deliberately excludes Scheme preparation while its owner optimizes it.
func BenchmarkGatewayPublishedPipeline(b *testing.B) {
	b.Run("registered", func(b *testing.B) { benchmarkRegisteredExecution(b, pb.Encoding_PROTOBUF, 1) })
}

// Six ABBA blocks, fresh stores, one immutable Rust image. Both arms use Arrow
// and the same five logical events; only bounded release coalescing differs.
func BenchmarkGatewayStreamingPair(b *testing.B) {
	for block := 0; block < 6; block++ {
		for index, rows := range []uint32{1, 32, 32, 1} {
			name := "single"
			if rows == 32 {
				name = "batch"
			}
			b.Run(fmt.Sprintf("%02d-%s", block*4+index, name), func(b *testing.B) { benchmarkRegisteredExecution(b, pb.Encoding_ARROW_IPC, rows) })
		}
	}
}

func benchmarkRegisteredExecution(b *testing.B, encoding pb.Encoding, rows uint32) {
	var data []byte
	prepare := func(b *testing.B, _ *fixture, bundle config.Bundle) {
		var err error
		data, err = json.Marshal(bundle)
		if err != nil {
			b.Fatal(err)
		}
	}
	activate := func(ctx context.Context, f *fixture, _ config.Bundle) (*controlplane.Gateway, error) {
		bundle, err := config.DecodeBundle(data, config.ProfileJSON)
		if err != nil {
			return nil, err
		}
		return controlplane.Bootstrap(ctx, f.admin, f.client, bundle)
	}
	benchmarkPublishedExecutionProfile(b, prepare, activate, encoding, rows)
}

// Shared actual service fixture, not a simulated transport. Only setup and
// activation differ between registered data and compiled Scheme source cases.
func benchmarkPublishedExecution(b *testing.B, prepare func(*testing.B, *fixture, config.Bundle), activate func(context.Context, *fixture, config.Bundle) (*controlplane.Gateway, error)) {
	benchmarkPublishedExecutionProfile(b, prepare, activate, pb.Encoding_PROTOBUF, 1)
}
func benchmarkPublishedExecutionProfile(b *testing.B, prepare func(*testing.B, *fixture, config.Bundle), activate func(context.Context, *fixture, config.Bundle) (*controlplane.Gateway, error), encoding pb.Encoding, rows uint32) {
	benchmarkPublishedExecutionHandler(b, prepare, activate, encoding, rows, completeSSE)
}
func benchmarkPublishedExecutionHandler(b *testing.B, prepare func(*testing.B, *fixture, config.Bundle), activate func(context.Context, *fixture, config.Bundle) (*controlplane.Gateway, error), encoding pb.Encoding, rows uint32, handler http.HandlerFunc) {
	var activation, sending time.Duration
	b.ReportAllocs()
	b.StopTimer()
	for range b.N {
		f := newFixture(b, handler, false)
		bundle := controlBundle(b, f)
		prepare(b, f, bundle)
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		b.Cleanup(cancel)
		b.StartTimer()
		started := time.Now()
		gateway, err := activate(ctx, f, bundle)
		activation += time.Since(started)
		if err != nil {
			b.Fatal(err)
		}
		if f.primary.Load() != 0 || f.backup.Load() != 0 || f.denied.Load() != 0 {
			b.Fatal("preparation/publication sent provider bytes")
		}
		b.StopTimer()
		listener, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			b.Fatal(err)
		}
		b.Cleanup(func() { listener.Close() })
		certificate, err := tls.X509KeyPair(f.pki.serverPEM, f.pki.serverKey)
		if err != nil {
			b.Fatal(err)
		}
		server, err := controlplane.NewServer(gateway, &tls.Config{Certificates: []tls.Certificate{certificate}, ClientCAs: f.pki.root, ClientAuth: tls.RequireAndVerifyClientCert}, sha256.Sum256(f.pki.client.Certificate[0]), sha256.Sum256([]byte(ownerToken)))
		if err != nil {
			b.Fatal(err)
		}
		b.Cleanup(server.GracefulStop)
		exited := make(chan error, 1)
		go func() { exited <- server.Serve(listener) }()
		client, err := gatewayclient.Dial(ctx, listener.Addr().String(), ownerToken, connectionTLS(f))
		if err != nil {
			b.Fatal(err)
		}
		b.Cleanup(func() { client.Connection.Close() })
		b.StartTimer()
		started = time.Now()
		texts := 0
		receipt, err := client.Execute(ctx, bundle.Plans[0], encoding, rows, func(event *pb.Event) error {
			if event.Text != "" {
				texts++
			}
			return nil
		})
		sending += time.Since(started)
		b.StopTimer()
		if err != nil || receipt.State != "complete" || receipt.Held != 4 || receipt.Events != 5 || texts != 2 || f.primary.Load() != 1 || f.backup.Load() != 0 || f.denied.Load() != 0 {
			b.Fatalf("fresh final send: %v %v texts=%d calls=%d", receipt, err, texts, f.primary.Load())
		}
		if _, err := client.Execute(ctx, bundle.Plans[0], encoding, rows, func(*pb.Event) error { b.Error("replay produced a frame"); return nil }); err == nil || f.primary.Load() != 1 {
			b.Fatal("retry duplicated original send", err)
		}
		if os.Getenv("WEAVER_TEST_SOURCE_MEASURE") != "" {
			data, err := os.ReadFile(filepath.Join(f.directory, "server.log"))
			if err != nil {
				b.Fatal(err)
			}
			for _, line := range strings.Split(string(data), "\n") {
				if strings.HasPrefix(line, "weaver source metric=") {
					b.Log(line)
				}
			}
		}
		client.Connection.Close()
		server.GracefulStop()
		if err := <-exited; err != nil {
			b.Fatal(err)
		}
		cancel()
		f.stop(b)
	}
	b.ReportMetric(float64(activation.Nanoseconds())/float64(b.N), "activation-ns/op")
	b.ReportMetric(float64(sending.Nanoseconds())/float64(b.N), "send-ns/op")
}

// Same immutable optimized service image, six fresh-store ABBA blocks. This is
// sensitivity to provider header latency, not an enabled early-unlock candidate.
func BenchmarkGatewayHeaderWaitPair(b *testing.B) {
	for block := 0; block < 6; block++ {
		for index, delayed := range []bool{false, true, true, false} {
			name := "immediate"
			if delayed {
				name = "delayed"
			}
			b.Run(fmt.Sprintf("%02d-%s", block*4+index, name), func(b *testing.B) {
				prepare := func(*testing.B, *fixture, config.Bundle) {}
				activate := func(ctx context.Context, f *fixture, bundle config.Bundle) (*controlplane.Gateway, error) {
					return controlplane.Bootstrap(ctx, f.admin, f.client, bundle)
				}
				handler := func(w http.ResponseWriter, r *http.Request) {
					if _, err := io.Copy(io.Discard, r.Body); err != nil {
						b.Error(err)
						return
					}
					if delayed {
						time.Sleep(30 * time.Millisecond)
					}
					completeSSE(w, r)
				}
				benchmarkPublishedExecutionHandler(b, prepare, activate, pb.Encoding_PROTOBUF, 1, handler)
			})
		}
	}
}
