package dev

import (
	"context"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/types/descriptorpb"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestGeneratedRPCMatchesSharedSchema(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	path := filepath.Join(t.TempDir(), "schema.pb")
	cmd := exec.CommandContext(ctx, "protoc", "--descriptor_set_out="+path, "-I", "proto", "proto/gateway/v1/gateway.proto")
	cmd.Dir = root(t)
	if data, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("schema compilation: %v: %s", err, data)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var set descriptorpb.FileDescriptorSet
	if err := proto.Unmarshal(data, &set); err != nil {
		t.Fatal(err)
	}
	if len(set.File) != 1 {
		t.Fatal("unexpected protocol descriptor closure")
	}
	if !proto.Equal(set.File[0], protodesc.ToFileDescriptorProto(pb.File_gateway_v1_gateway_proto)) {
		t.Fatal("generated Go RPC differs from shared source; run weaver-dev generate-rpc")
	}
}
