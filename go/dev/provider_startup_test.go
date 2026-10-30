//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"fmt"
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
	source, err := os.Open(serverBinary)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	path := filepath.Join(t.TempDir(), "weaver-server")
	target, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0700)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.New()
	_, copyError := io.Copy(io.MultiWriter(target, hash), source)
	syncError := target.Sync()
	closeError := target.Close()
	if copyError != nil || syncError != nil || closeError != nil {
		t.Fatalf("fresh image: copy=%v sync=%v close=%v", copyError, syncError, closeError)
	}
	t.Logf("fresh image sha256=%s", fmt.Sprintf("%x", hash.Sum(nil)))
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
