// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"reflect"
	"strings"
	"testing"
)

func artifactFixture(t testing.TB) (*pb.SourceArtifact, config.Bundle) {
	t.Helper()
	profile := &v1.ProviderProfile{ID: "p", Protocol: v1.ChatTextSSE, MaxOutputTokens: 32, MaxMessages: 1, MaxBodyBytes: 4096}
	commitment, err := profile.Digest()
	if err != nil {
		t.Fatal(err)
	}
	p := v1.ProviderPlan{Family: "f", Node: "infer", Profile: "p", ProfileCommitment: commitment, Model: "m",
		Body:   `{"model":"m","stream":true,"messages":[{"role":"user","content":"hello"}],"max_tokens":8}`,
		Routes: []v1.ProviderRoute{{Target: "primary", Endpoint: "https://provider.invalid/v1/chat/completions"}}, Ceiling: 4}
	digest, err := p.Digest()
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(p.Body))
	revision := uint64(0)
	task := v1.Task{Family: "f", Principal: "alice", Profile: "p", ProviderProfile: profile, Nodes: []string{"infer"}, Targets: []string{"primary"}, Models: []string{"m"},
		Endpoints: map[string]string{"primary": p.Routes[0].Endpoint}, BodyDigests: map[string]string{"infer": hex.EncodeToString(sum[:])},
		StreamContracts: map[string]string{"infer": digest}, NodeCostBounds: map[string]uint64{"infer": 4}, Budget: 8}
	bundle := config.Bundle{Governance: config.Governance{Schema: "agentic-ai-lab.loop-governor.v1", Family: "f", OpenNodes: []string{"infer"}},
		Tasks: []v1.Task{task}, Plans: []v1.ProviderPlan{p}, Publication: v1.Publication{OperationID: "source", ExpectedRevision: &revision, Fence: 1, Policy: "permit(principal,action,resource);", Schema: "{}"}}
	return &pb.SourceArtifact{Governance: &pb.GovernanceSelection{Schema: bundle.Governance.Schema, Family: "f", OpenNodes: []string{"infer"}},
		Tasks: []*pb.Task{gatewayclient.Task(task)}, Plans: []*pb.ProviderPlan{gatewayclient.Plan(p)}, Publication: gatewayclient.Publication(bundle.Publication)}, bundle
}
func FuzzCompiledSourceOwnershipAndBinding(f *testing.F) {
	f.Add(uint8(0))
	f.Add(uint8(6))
	f.Fuzz(func(t *testing.T, field uint8) {
		input, expected := artifactFixture(t)
		data, err := proto.Marshal(input)
		if err != nil {
			t.Fatal(err)
		}
		wire := &pb.SourceArtifact{}
		if err := proto.Unmarshal(data, wire); err != nil {
			t.Fatal(err)
		}
		owned, err := compiledBundle(wire)
		if err != nil || !reflect.DeepEqual(owned, expected) {
			t.Fatal("typed source diverged", err)
		}
		switch field % 7 {
		case 0:
			wire.Governance.OpenNodes[0] = "replacement"
		case 1:
			wire.Tasks[0].Nodes[0] = "replacement"
		case 2:
			wire.Tasks[0].Endpoints["primary"] = "https://replacement.invalid"
		case 3:
			wire.Tasks[0].ProviderProfile.MaxOutputTokens = 1
		case 4:
			wire.Plans[0].Routes[0].Endpoint = "https://replacement.invalid"
		case 5:
			wire.Plans[0].Body[0] = 0
		case 6:
			*wire.Publication.ExpectedRevision = 99
		}
		if !reflect.DeepEqual(owned, expected) {
			t.Fatal("source followed protobuf-owned storage")
		}
		_, err = compiledBundle(wire)
		// A different expected revision is still consistent proposal data.
		// Original provenance comes from the authenticated server's catalog;
		// only the final publication CAS decides whether that parent is current.
		if field%7 != 6 && err == nil {
			t.Fatal("malformed binding accepted")
		}
		if field%7 == 6 && err != nil {
			t.Fatal("valid proposal was mistaken for authority", err)
		}
	})
}
func TestCompiledSourceRejectsUnsupportedMessageFields(t *testing.T) {
	for field := 0; field < 7; field++ {
		input, _ := artifactFixture(t)
		messages := []proto.Message{input, input.Governance, input.Publication, input.Tasks[0], input.Tasks[0].ProviderProfile, input.Plans[0], input.Plans[0].Routes[0]}
		messages[field].ProtoReflect().SetUnknown([]byte{0x98, 0x06, 1})
		if _, err := compiledBundle(input); err == nil {
			t.Fatal("unsupported source semantics accepted", field)
		}
	}
}

type sourceRPC struct {
	pb.GatewayClient
	calls        []string
	artifact     *pb.SourceArtifact
	publication  v1.Publication
	failCompile  bool
	failRegister bool
}

func (r *sourceRPC) CompileSource(context.Context, *pb.ProducerRequest, ...grpc.CallOption) (*pb.CompiledSource, error) {
	r.calls = append(r.calls, "compile")
	if r.failCompile {
		return nil, errors.New("compile unavailable")
	}
	return &pb.CompiledSource{Producer: "approved", Authority: &pb.SourceAuthorityView{Epoch: 0, IdentityDigest: strings.Repeat("1", 64)}, Artifact: r.artifact}, nil
}
func (r *sourceRPC) InspectSourceAuthority(context.Context, *pb.Empty, ...grpc.CallOption) (*pb.SourceAuthorityView, error) {
	r.calls = append(r.calls, "source-view")
	return &pb.SourceAuthorityView{Epoch: 0, IdentityDigest: strings.Repeat("1", 64)}, nil
}
func (r *sourceRPC) InspectPublication(context.Context, *pb.PublicationKey, ...grpc.CallOption) (*pb.PublicationReceipt, error) {
	r.calls = append(r.calls, "inspect")
	return nil, status.Error(codes.NotFound, "original not committed")
}
func (r *sourceRPC) StageAuthority(context.Context, *pb.PublishRequest, ...grpc.CallOption) (*pb.PublicationKey, error) {
	r.calls = append(r.calls, "stage")
	digest, err := r.publication.Digest()
	return &pb.PublicationKey{OperationId: r.publication.OperationID, Digest: digest}, err
}
func (r *sourceRPC) RegisterPublishedTask(context.Context, *pb.RegisterPublishedTaskRequest, ...grpc.CallOption) (*pb.Empty, error) {
	r.calls = append(r.calls, "register")
	if r.failRegister {
		return nil, errors.New("task registration failed")
	}
	return &pb.Empty{}, nil
}
func (r *sourceRPC) PublishAuthority(context.Context, *pb.PublishRequest, ...grpc.CallOption) (*pb.PublicationReceipt, error) {
	r.calls = append(r.calls, "publish")
	digest, err := r.publication.Digest()
	revision := uint64(1)
	fence := r.publication.Fence
	return &pb.PublicationReceipt{OperationId: r.publication.OperationID, Digest: digest, Outcome: pb.PublicationOutcome_COMMITTED, Revision: &revision, Fence: &fence}, err
}
func TestRegisteredBootstrapKeepsCompilationStagingAndFinalPublicationOrdered(t *testing.T) {
	for _, mode := range []string{"ok", "compile-failed", "register-failed"} {
		t.Run(mode, func(t *testing.T) {
			input, bundle := artifactFixture(t)
			rpc := &sourceRPC{artifact: input, publication: bundle.Publication, failCompile: mode == "compile-failed", failRegister: mode == "register-failed"}
			client := &gatewayclient.Client{RPC: rpc, Token: "source-token"}
			_, err := BootstrapProducer(context.Background(), client, client, "approved")
			expected := []string{"compile", "source-view", "inspect", "stage", "register", "publish"}
			if mode == "compile-failed" {
				expected = expected[:1]
			}
			if mode == "register-failed" {
				expected = expected[:5]
			}
			if !reflect.DeepEqual(rpc.calls, expected) || (err == nil) != (mode == "ok") {
				t.Fatal("source protocol ordering or activation changed", rpc.calls, err)
			}
		})
	}
}
