//go:build integration && schemeintegration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/controlplane"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
)

// Fresh Scheme assessment/Cedar, authenticated Go publication, routing and Rust
// durable final send. Each sample uses a fresh ledger/original. Replay is checked
// outside the timer. Builds, VM/server startup, PKI and frontend TLS setup are
// excluded. Allocations describe Go only; local HTTPS is not a provider SLA.
func BenchmarkGatewayCompiledPipeline(b *testing.B) {
	for _, assets := range []bool{false, true} {
		name := "inline"
		if assets {
			name = "assets"
		}
		b.Run(name, func(b *testing.B) {
			var activation, sending time.Duration
			b.ReportAllocs()
			b.StopTimer()
			for range b.N {
				f := newFixture(b, completeSSE, false)
				bundle := controlBundle(b, f)
				catalog := configuredCatalogPath(b, f, bundle)
				f.stop(b)
				f.env = append(f.env, "WEAVER_GOVERNANCE_CATALOG="+catalog)
				if assets {
					dir := filepath.Join(f.directory, "assets")
					if err := os.Mkdir(dir, 0700); err != nil {
						b.Fatal(err)
					}
					if err := os.WriteFile(filepath.Join(dir, "policy.cedar"), []byte(bundle.Publication.Policy), 0600); err != nil {
						b.Fatal(err)
					}
					f.env = append(f.env, "WEAVER_TEST_GOVERNANCE_ASSET_ROOT="+dir)
				}
				f.start(b)
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				b.Cleanup(cancel)
				b.StartTimer()
				started := time.Now()
				gateway, err := controlplane.BootstrapProducer(ctx, f.admin, f.client, "approved-control")
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
				receipt, err := client.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1, func(event *pb.Event) error {
					if event.Text != "" {
						texts++
					}
					return nil
				})
				sending += time.Since(started)
				b.StopTimer()
				if err != nil || receipt.State != "complete" || receipt.Held != 4 || texts != 2 || f.primary.Load() != 1 || f.backup.Load() != 0 || f.denied.Load() != 0 {
					b.Fatalf("fresh final send: %v %v texts=%d calls=%d", receipt, err, texts, f.primary.Load())
				}
				if _, err := client.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { b.Error("replay produced a frame"); return nil }); err == nil || f.primary.Load() != 1 {
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
		})
	}
}
