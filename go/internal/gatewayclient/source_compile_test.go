// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package gatewayclient

import (
	"context"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/grpc"
	"strings"
	"testing"
)

type compileRPC struct {
	pb.GatewayClient
	calls, reads int
	reply        *pb.CompiledSource
	current      *pb.SourceAuthorityView
	failure      error
}

func (r *compileRPC) CompileSource(_ context.Context, request *pb.ProducerRequest, _ ...grpc.CallOption) (*pb.CompiledSource, error) {
	r.calls++
	if request.Producer != "approved" {
		return nil, errors.New("wrong producer")
	}
	return r.reply, r.failure
}
func (r *compileRPC) InspectSourceAuthority(context.Context, *pb.Empty, ...grpc.CallOption) (*pb.SourceAuthorityView, error) {
	r.reads++
	return r.current, nil
}
func compileReply() *pb.CompiledSource {
	return &pb.CompiledSource{Producer: "approved", Authority: &pb.SourceAuthorityView{Epoch: 0, IdentityDigest: strings.Repeat("1", 64)}, Artifact: &pb.SourceArtifact{}}
}
func TestCompileSourceNeverRetriesOrAdoptsWrongProducerAndAuthority(t *testing.T) {
	for _, mode := range []string{"ok", "lost-response", "nil", "producer", "authority", "changed-epoch", "changed-identity"} {
		t.Run(mode, func(t *testing.T) {
			reply := compileReply()
			current := &pb.SourceAuthorityView{Epoch: 0, IdentityDigest: strings.Repeat("1", 64)}
			rpc := &compileRPC{reply: reply, current: current}
			switch mode {
			case "lost-response":
				rpc.failure = errors.New("indeterminate compilation")
			case "nil":
				rpc.reply = nil
			case "producer":
				reply.Producer = "replacement"
			case "authority":
				reply.Authority = nil
			case "changed-epoch":
				current.Epoch = 1
			case "changed-identity":
				current.IdentityDigest = strings.Repeat("2", 64)
			}
			client := &Client{RPC: rpc, Token: "source-token"}
			_, err := client.CompileSource(context.Background(), "approved")
			if (err == nil) != (mode == "ok") || rpc.calls != 1 {
				t.Fatal("bad source binding/retry", err, rpc.calls)
			}
		})
	}
}
func FuzzCompileSourceEchoAndCurrentAuthority(f *testing.F) {
	f.Add("approved", uint64(0), strings.Repeat("1", 64))
	f.Add("replacement", uint64(1), strings.Repeat("2", 64))
	f.Fuzz(func(t *testing.T, name string, epoch uint64, identity string) {
		if len(name) > 256 || len(identity) > 256 {
			return
		}
		reply := compileReply()
		reply.Producer = name
		rpc := &compileRPC{reply: reply, current: &pb.SourceAuthorityView{Epoch: epoch, IdentityDigest: identity}}
		_, err := (&Client{RPC: rpc, Token: "source-token"}).CompileSource(context.Background(), "approved")
		valid := name == "approved" && epoch == 0 && identity == strings.Repeat("1", 64)
		if (err == nil) != valid || rpc.calls != 1 {
			t.Fatal("source binding or retry diverged")
		}
	})
}
