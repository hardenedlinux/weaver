// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/tls"
	"net"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/controlplane"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
)

// An existing operation-role worker tries the newly visible task immediately
// after registration, before bootstrap can request its final publication.
type sourceOrderingProbe struct {
	*publicationReplyLoss
	operation *gatewayclient.Client
	plan      v1.ProviderPlan
}

type missingPublishedRegistration struct {
	pb.GatewayClient
	rawRegistrations int
}

func (p *missingPublishedRegistration) RegisterPublishedTask(context.Context, *pb.RegisterPublishedTaskRequest, ...grpc.CallOption) (*pb.Empty, error) {
	return nil, status.Error(codes.Unimplemented, "publication-bound registration unavailable")
}
func (p *missingPublishedRegistration) RegisterTask(ctx context.Context, in *pb.RegisterTaskRequest, options ...grpc.CallOption) (*pb.Empty, error) {
	p.rawRegistrations++
	return p.GatewayClient.RegisterTask(ctx, in, options...)
}

func TestProviderControlCannotDowngradePublicationBoundRegistration(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	proxy := &missingPublishedRegistration{GatewayClient: f.admin.RPC}
	source := *f.admin
	source.RPC = proxy
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if _, err := controlplane.Bootstrap(ctx, &source, f.client, controlBundle(t, f)); status.Code(err) != codes.Unimplemented {
		t.Fatal("unsupported task-origin capability did not stop activation", err)
	}
	if proxy.rawRegistrations != 0 || f.primary.Load()+f.backup.Load()+f.denied.Load() != 0 {
		t.Fatal("source task registration silently fell back to a weaker capability")
	}
}

func (p *sourceOrderingProbe) RegisterPublishedTask(ctx context.Context, in *pb.RegisterPublishedTaskRequest) (*pb.Empty, error) {
	source := p.sourceClient()
	result, err := source.RPC.RegisterPublishedTask(source.Context(ctx), in)
	if err != nil {
		return nil, err
	}
	_, _ = p.operation.Execute(ctx, p.plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil })
	return result, nil
}
func (p *sourceOrderingProbe) PublishAuthority(ctx context.Context, in *pb.PublishRequest) (*pb.PublicationReceipt, error) {
	source := p.sourceClient()
	return source.RPC.PublishAuthority(source.Context(ctx), in)
}

func TestProviderControlStagesBeforeTaskRegistration(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	parent := uint64(0)
	if _, err := f.admin.Publish(ctx, v1.Publication{OperationID: "old-broad-policy", ExpectedRevision: &parent, Fence: 2, Policy: "permit(principal,action,resource);", Schema: f.schema}); err != nil {
		t.Fatal(err)
	}
	bundle := controlBundle(t, f)
	parent = 1
	bundle.Publication.ExpectedRevision = &parent
	bundle.Publication.Fence = 3
	bundle.Publication.Policy = "forbid(principal,action,resource);"
	for i := range bundle.Plans {
		bundle.Plans[i].Revision = 2
		bundle.Plans[i].Fence = 3
	}
	probePlan := bundle.Plans[0]
	probePlan.Revision = 1
	probePlan.Fence = 2
	probe := &sourceOrderingProbe{publicationReplyLoss: &publicationReplyLoss{source: f.admin}, operation: f.client, plan: probePlan}
	certificate, err := tls.X509KeyPair(f.pki.serverPEM, f.pki.serverKey)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer(grpc.Creds(credentials.NewTLS(&tls.Config{Certificates: []tls.Certificate{certificate}, ClientCAs: f.pki.root, ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS13})))
	pb.RegisterGatewayServer(server, probe)
	exited := make(chan error, 1)
	go func() { exited <- server.Serve(listener) }()
	t.Cleanup(func() { server.Stop(); <-exited })
	c := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	c.env = append(c.env, "WEAVER_CONTROL_AUTHORITY_SOURCE_ADDRESS="+listener.Addr().String())
	c.start(t)
	if f.primary.Load()+f.backup.Load()+f.denied.Load() != 0 {
		t.Fatal("new task escaped through old Policy before its pending barrier")
	}
}

func TestProviderRejectedTaskPublicationCannotUseUnrelatedAllowingImage(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	parent := uint64(0)
	if _, err := f.admin.Publish(ctx, v1.Publication{OperationID: "old-broad-policy", ExpectedRevision: &parent, Fence: 2, Policy: "permit(principal,action,resource);", Schema: f.schema}); err != nil {
		t.Fatal(err)
	}
	bundle := controlBundle(t, f)
	parent = 99
	bundle.Publication.ExpectedRevision = &parent
	bundle.Publication.Fence = 3
	key, err := f.admin.RPC.StageAuthority(f.admin.Context(ctx), gatewayclient.Publication(bundle.Publication))
	if err != nil {
		t.Fatal(err)
	}
	task := gatewayclient.Task(bundle.Tasks[0])
	if _, err = f.admin.RPC.RegisterPublishedTask(f.admin.Context(ctx), &pb.RegisterPublishedTaskRequest{Task: task, Publication: key}); err != nil {
		t.Fatal(err)
	}
	if r, err := f.admin.FinalizePublication(ctx, bundle.Publication); err != gatewayclient.ErrPublicationRejected || r.GetOutcome() != pb.PublicationOutcome_REJECTED {
		t.Fatal("expected immutable rejection", r, err)
	}
	probe := bundle.Plans[0]
	probe.Revision = 1
	probe.Fence = 2
	for range 2 {
		if _, err = f.client.Execute(ctx, probe, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
			t.Fatal("rejected original task publication authorized a provider call")
		}
		if f.primary.Load()+f.backup.Load()+f.denied.Load() != 0 {
			t.Fatal("rejected task reached a transport")
		}
		if _, err = f.admin.RPC.RegisterTask(f.admin.Context(ctx), &pb.RegisterTaskRequest{Task: task}); err != nil {
			t.Fatal(err)
		}
	}
	if receipt, observeErr := f.client.RPC.Inspect(f.client.Context(ctx), &pb.OperationKey{Family: probe.Family, Node: probe.Node}); observeErr == nil || receipt != nil {
		t.Fatal("unadmitted operation returned a positive receipt", receipt, observeErr)
	}
	// A failed observation is not a zero-balance/no-execution receipt. The native
	// ledger property separately checks that these refused admissions create no hold.
	// A separately admitted original task proves the old image really permits
	// transport; denial above cannot be explained by a closed TLS/credential path.
	f.plan.Revision = 1
	f.plan.Fence = 2
	_, _, _ = execute(t, f, pb.Encoding_PROTOBUF, 1)
	if f.primary.Load()+f.backup.Load()+f.denied.Load() != 1 {
		t.Fatal("allowing-image positive control never reached transport")
	}
}
