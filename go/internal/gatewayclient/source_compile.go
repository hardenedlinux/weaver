// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package gatewayclient

import (
	"context"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/protobuf/proto"
	"strings"
)

// CompileSource requests one installed producer, without replacement input or
// caller identity labels. It never retries or publishes. A returned source view
// is knowledge only; current mutation/final-use checks remain mandatory.
func (c *Client) CompileSource(ctx context.Context, producer string) (*pb.CompiledSource, error) {
	if c == nil || c.RPC == nil || c.Token == "" || producer == "" || len(producer) > 128 || strings.ContainsAny(producer, "\x00\r\n") {
		return nil, errors.New("registered producer required")
	}
	reply, err := c.RPC.CompileSource(c.Context(ctx), &pb.ProducerRequest{Producer: producer})
	if err != nil {
		return nil, err
	}
	if reply == nil || reply.Producer != producer || reply.Artifact == nil || !validSourceView(reply.Authority) || proto.Size(reply) > 4*1024*1024 || len(reply.ProtoReflect().GetUnknown()) != 0 || len(reply.Authority.ProtoReflect().GetUnknown()) != 0 {
		return nil, errors.New("compiled source binding rejected")
	}
	current, err := c.SourceAuthority(ctx)
	if err != nil {
		return nil, err
	}
	if current.Epoch != reply.Authority.Epoch || current.IdentityDigest != reply.Authority.IdentityDigest {
		return nil, errors.New("compiled source authority changed")
	}
	return reply, nil
}
