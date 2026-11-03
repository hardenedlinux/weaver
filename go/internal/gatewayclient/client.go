// Package gatewayclient is the typed Go control-plane boundary to the Rust owner.
package gatewayclient

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"maps"
	"slices"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/backoff"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
)

type Client struct {
	Connection *grpc.ClientConn
	RPC        pb.GatewayClient
	Token      string
}

func Dial(ctx context.Context, address, token string, security *tls.Config) (*Client, error) {
	if security == nil || security.InsecureSkipVerify || len(security.Certificates) == 0 || security.RootCAs == nil || token == "" {
		return nil, errors.New("explicit mutual TLS and operation credential required")
	}
	settings := security.Clone()
	settings.MinVersion = tls.VersionTLS13
	// Retain exponential growth, jitter and the long-outage cap. Only the
	// initial transport delay changes; final-budget readiness also caps stale
	// backoff. No application RPC is sent or retried.
	connectionBackoff := backoff.DefaultConfig
	connectionBackoff.BaseDelay = 100 * time.Millisecond
	conn, err := grpc.DialContext(ctx, address, grpc.WithTransportCredentials(credentials.NewTLS(settings)), grpc.WithConnectParams(grpc.ConnectParams{Backoff: connectionBackoff, MinConnectTimeout: 20 * time.Second}), grpc.WithDisableRetry(), grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(4*1024*1024), grpc.MaxCallSendMsgSize(2*1024*1024)))
	if err != nil {
		return nil, err
	}
	if err := awaitReady(ctx, conn, connectionBackoff.BaseDelay); err != nil {
		conn.Close()
		return nil, err
	}
	return &Client{Connection: conn, RPC: pb.NewGatewayClient(conn), Token: token}, nil
}

// Only initial transport establishment uses the final portion of the caller's
// existing budget. Once Ready, native exponential reconnect/backoff is unchanged.
// No application RPC is issued, retried or authorized by observing Ready.
func awaitReady(ctx context.Context, conn *grpc.ClientConn, interval time.Duration) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		state := conn.GetState()
		if state == connectivity.Ready {
			return nil
		}
		if state == connectivity.Idle {
			conn.Connect()
		}
		wait := ctx
		cancel := func() {}
		if deadline, ok := ctx.Deadline(); ok {
			edge := deadline.Add(-5 * interval)
			if time.Now().Before(edge) {
				wait, cancel = context.WithDeadline(ctx, edge)
			} else {
				wait, cancel = context.WithTimeout(ctx, interval)
			}
		}
		changed := conn.WaitForStateChange(wait, state)
		cancel()
		if !changed && ctx.Err() == nil {
			if deadline, ok := ctx.Deadline(); ok && time.Until(deadline) <= 5*interval && conn.GetState() == connectivity.TransientFailure {
				conn.ResetConnectBackoff()
			}
		}
	}
}
func (c *Client) Context(ctx context.Context) context.Context {
	return metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+c.Token)
}
func Plan(p v1.ProviderPlan) *pb.ProviderPlan {
	routes := make([]*pb.Route, 0, len(p.Routes))
	for _, r := range p.Routes {
		routes = append(routes, &pb.Route{Target: r.Target, Endpoint: r.Endpoint})
	}
	return &pb.ProviderPlan{Family: p.Family, Node: p.Node, Profile: p.Profile, ProfileCommitment: p.ProfileCommitment, Model: p.Model, Body: []byte(p.Body), Routes: routes, Ceiling: p.Ceiling, Revision: p.Revision, Fence: p.Fence}
}
func Task(t v1.Task) *pb.Task {
	var profile *pb.ProviderProfile
	if p := t.ProviderProfile; p != nil {
		profile = &pb.ProviderProfile{Id: p.ID, Protocol: p.Protocol, MaxOutputTokens: p.MaxOutputTokens, MaxMessages: p.MaxMessages, MaxBodyBytes: p.MaxBodyBytes}
	}
	return &pb.Task{Family: t.Family, Principal: t.Principal, Profile: t.Profile, ProviderProfile: profile, Nodes: slices.Clone(t.Nodes), Targets: slices.Clone(t.Targets), Endpoints: maps.Clone(t.Endpoints), BodyDigests: maps.Clone(t.BodyDigests), NodeCostBounds: maps.Clone(t.NodeCostBounds), StreamContracts: maps.Clone(t.StreamContracts), Models: slices.Clone(t.Models), Budget: t.Budget}
}

// Execute never retries. A disconnected, partial or indeterminate operation must
// be inspected under its original key. A DONE event alone is not a durable receipt.
func (c *Client) Execute(ctx context.Context, p v1.ProviderPlan, encoding pb.Encoding, batchRows uint32, receive func(*pb.Event) error) (*pb.ProviderReceipt, error) {
	if len(p.Routes) == 0 || len(p.Routes) > 8 {
		return nil, errors.New("provider route bound")
	}
	// Strings/scalars already have value semantics. Retain the sole mutable
	// plan field before invoking RPC or user callbacks; no wire object aliases it.
	// The caller must keep input stable during this initial bounded copy.
	p.Routes = slices.Clone(p.Routes)
	streamCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	stream, err := c.RPC.ExecuteProvider(c.Context(streamCtx), &pb.ProviderRequest{Plan: Plan(p), Encoding: encoding, BatchRows: batchRows})
	if err != nil {
		return nil, err
	}
	next := uint64(0)
	done := false
	finished, used := false, false
	selected := ""
	for {
		frame, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		if done || frame.Model != p.Model {
			return nil, errors.New("provider response mode changed")
		}
		permitted := false
		for _, route := range p.Routes {
			if frame.Target == route.Target {
				permitted = true
			}
		}
		if !permitted {
			return nil, errors.New("provider response route changed")
		}
		if selected == "" {
			selected = frame.Target
		}
		if selected != frame.Target {
			return nil, errors.New("provider changed inside original stream")
		}
		events, err := Events(frame, encoding)
		if err != nil {
			return nil, err
		}
		for _, event := range events {
			if done || event.Sequence != next || next >= 4096 || len(event.Text) > 65536 {
				return nil, errors.New("provider response sequence changed")
			}
			switch event.Kind {
			case "delta":
				if finished {
					return nil, errors.New("delta after finish")
				}
			case "finish":
				if finished {
					return nil, errors.New("repeated finish")
				}
				finished = true
			case "usage":
				if !finished || used {
					return nil, errors.New("usage order")
				}
				used = true
			case "done":
				if !finished {
					return nil, errors.New("done before finish")
				}
			default:
				return nil, errors.New("unregistered response event kind")
			}
			next++
			done = event.Kind == "done"
			if err := receive(event); err != nil {
				return nil, err
			}
		}
	}
	if !done {
		return nil, errors.New("provider response incomplete; do not retry")
	}
	receipt, err := c.RPC.Inspect(c.Context(ctx), &pb.OperationKey{Family: p.Family, Node: p.Node})
	if err != nil {
		return nil, err
	}
	digest, digestErr := p.Digest()
	if digestErr != nil || receipt.Digest != digest || receipt.Family != p.Family || receipt.Node != p.Node || receipt.Target != selected || receipt.Reserved != p.Ceiling || receipt.Held < receipt.Reserved || receipt.State != "complete" || receipt.Events != next {
		return receipt, errors.New("provider completion remains indeterminate")
	}
	return receipt, nil
}
