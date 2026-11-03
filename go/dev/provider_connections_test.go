// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/tls"
	"errors"
	"net"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
)

func connectionTLS(f *fixture) *tls.Config {
	return &tls.Config{RootCAs: f.pki.root, Certificates: []tls.Certificate{f.pki.client}, ServerName: "localhost", MinVersion: tls.VersionTLS13, NextProtos: []string{"h2"}}
}

func blockedHandshake(t *testing.T, f *fixture) {
	blockedHandshakeAt(t, f.address, connectionTLS(f))
}

func blockedHandshakeAt(t *testing.T, address string, security *tls.Config) {
	t.Helper()
	socket, err := net.DialTimeout("tcp4", address, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	conn := tls.Client(socket, security)
	err = conn.HandshakeContext(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("connection beyond global bound reached TLS: %v", err)
	}
}

func TestProviderConnectionBoundRetainsExistingAuthorityChannel(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	if _, _, err := execute(t, f, pb.Encoding_PROTOBUF, 1); err != nil {
		t.Fatal(err)
	}
	// The fixture already has one authenticated HTTP/2 connection.
	var idle []*tls.Conn
	t.Cleanup(func() {
		for _, conn := range idle {
			conn.Close()
		}
	})
	for range 15 {
		conn, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp4", f.address, connectionTLS(f))
		if err != nil {
			t.Fatal(err)
		}
		idle = append(idle, conn) // Deliberately omit the HTTP/2 preface.
	}
	blockedHandshake(t, f)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	revision := uint64(0)
	if receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "connection-revoke", ExpectedRevision: &revision, Fence: 2, Policy: "forbid(principal,action,resource);", Schema: f.schema}); err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatalf("existing authority channel blocked: %v", err)
	}
	if receipt := inspect(t, f); receipt.Held != 4 || receipt.State != "complete" {
		t.Fatalf("connection pressure changed original receipt: %v", receipt)
	}
	idle[0].Close()
	replacement, err := tls.DialWithDialer(&net.Dialer{Timeout: 3 * time.Second}, "tcp4", f.address, connectionTLS(f))
	if err != nil {
		t.Fatalf("destroyed connection did not return capacity: %v", err)
	}
	replacement.Close()
}

func TestProviderPreTLSConnectionsAreBoundedAndExpire(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	var stalled []net.Conn
	t.Cleanup(func() {
		for _, conn := range stalled {
			conn.Close()
		}
	})
	for range 15 {
		conn, err := net.DialTimeout("tcp4", f.address, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		stalled = append(stalled, conn)
	}
	blockedHandshake(t, f)
	// The fixed server-side TLS deadline is three seconds, independent of RPC deadlines.
	deadline := time.Now().Add(4 * time.Second)
	for _, conn := range stalled {
		conn.SetReadDeadline(deadline)
		var buffer [1]byte
		if _, err := conn.Read(buffer[:]); err == nil {
			t.Fatal("plaintext client received application bytes")
		} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
			t.Fatalf("TLS handshake did not expire: %v", err)
		}
	}
	replacement, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp4", f.address, connectionTLS(f))
	if err != nil {
		t.Fatalf("expired handshake leaked capacity: %v", err)
	}
	replacement.Close()
	f.stop(t) // Existing fixed fifteen-second natural-drain gate remains in force.
}

func TestProviderShutdownDestroysStalledTLSBeforeAcknowledgingExit(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	var stalled []net.Conn
	t.Cleanup(func() {
		for _, conn := range stalled {
			conn.Close()
		}
	})
	for _, ingress := range []struct {
		address string
		count   int
	}{{f.address, 15}, {f.sourceAddress, 3}} {
		for range ingress.count {
			conn, err := net.DialTimeout("tcp4", ingress.address, time.Second)
			if err != nil {
				t.Fatal(err)
			}
			stalled = append(stalled, conn)
		}
	}
	f.stop(t)
	for _, conn := range stalled {
		conn.SetReadDeadline(time.Now().Add(time.Second))
		var buffer [1]byte
		if _, err := conn.Read(buffer[:]); err == nil {
			t.Fatal("connection survived natural server exit")
		} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
			t.Fatalf("stalled connection survived shutdown: %v", err)
		}
	}
}
