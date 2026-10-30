package gatewayclient

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"testing"
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
