// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package main

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/metering"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) != 3 {
		return errors.New("usage: weaver-meter FAMILY NODE")
	}
	cert, err := tls.LoadX509KeyPair(os.Getenv("WEAVER_METER_TLS_CERT"), os.Getenv("WEAVER_METER_TLS_KEY"))
	if err != nil {
		return err
	}
	ca, err := os.ReadFile(os.Getenv("WEAVER_METER_TLS_CA"))
	if err != nil {
		return err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		return errors.New("meter CA required")
	}
	file, err := os.Open(os.Getenv("WEAVER_METER_SIGNING_SEED"))
	if err != nil {
		return err
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, 129))
	if err != nil {
		return err
	}
	seed, err := hex.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(seed) != ed25519.SeedSize {
		return errors.New("invalid meter signing seed")
	}
	issuer := metering.Issuer{Audience: os.Getenv("WEAVER_METER_AUDIENCE"), Tenant: os.Getenv("WEAVER_METER_TENANT"),
		ID: os.Getenv("WEAVER_METER_ISSUER"), Key: ed25519.NewKeyFromSeed(seed)}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	client, err := gatewayclient.Dial(ctx, os.Getenv("WEAVER_METER_SOURCE_ADDR"), os.Getenv("WEAVER_METER_TOKEN"),
		&tls.Config{Certificates: []tls.Certificate{cert}, RootCAs: roots, ServerName: os.Getenv("WEAVER_METER_TLS_SERVER_NAME")})
	if err != nil {
		return err
	}
	defer client.Connection.Close()
	result, err := issuer.Settle(client.Context(ctx), client.RPC, &pb.OperationKey{Family: os.Args[1], Node: os.Args[2]})
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(result)
}
