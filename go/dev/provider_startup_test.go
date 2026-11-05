// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A fresh file is a deployment-image witness, not a claim of flushed OS caches.
// Both its first launch and exact-image restart keep the original three-second gate.
func TestProviderFreshImageAndRestartStartup(t *testing.T) {
	path := copyStartupImage(t)
	checkStartupImage(t, path)
}

func copyStartupImage(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "weaver-server")
	digest, err := publishProviderImage(serverBinary, path)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("copied image sha256=%s", digest)
	return path
}

func checkStartupImage(t *testing.T, path string) {
	t.Helper()
	image, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.New()
	_, hashError := io.Copy(hash, image)
	closeError := image.Close()
	if hashError != nil || closeError != nil {
		t.Fatal(hashError, closeError)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("executed image bytes=%d sha256=%x", info.Size(), hash.Sum(nil))
	f := fixtureWithBinary(t, completeSSE, false, path)
	f.stop(t)
	f.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, err = f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: "f", Node: "infer"})
	// The public observation API deliberately maps missing operations to an
	// opaque FailedPrecondition; this is not a budget or no-execution certificate.
	if status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 0 || f.backup.Load() != 0 || f.denied.Load() != 0 {
		t.Fatal("startup issued or consumed an operation", err)
	}
}
