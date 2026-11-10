// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package controlplane

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func required(name string) (string, error) {
	v := os.Getenv(name)
	if v == "" {
		return "", fmt.Errorf("required setting: %s", name)
	}
	return v, nil
}
func fileSetting(name string) ([]byte, error) {
	path, err := required(name)
	if err != nil {
		return nil, err
	}
	return readBoundFile(path)
}
func readBoundFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, (8<<20)+1))
	if len(data) > 8<<20 {
		return nil, errors.New("deployment file bound")
	}
	return data, err
}
func pair(prefix string) (tls.Certificate, error) {
	certificate, err := fileSetting(prefix + "_CERT")
	if err != nil {
		return tls.Certificate{}, err
	}
	key, err := fileSetting(prefix + "_KEY")
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.X509KeyPair(certificate, key)
}
func roots(name string) (*x509.CertPool, error) {
	data, err := fileSetting(name)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(data) {
		return nil, errors.New("CA required")
	}
	return pool, nil
}
func digest(name string) ([32]byte, error) {
	var result [32]byte
	raw, err := required(name)
	if err != nil {
		return result, err
	}
	data, err := hex.DecodeString(raw)
	if err != nil || len(data) != 32 {
		return result, errors.New("SHA-256 setting required")
	}
	copy(result[:], data)
	return result, nil
}

func RunFromEnv(ctx context.Context) error {
	started := time.Now()
	trace := func(phase string) {
		slog.InfoContext(ctx, "Control startup", "phase", phase, "elapsed", time.Since(started))
	}
	trace("begin")
	startup, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	serverKey, err := pair("WEAVER_CONTROL_SERVER")
	if err != nil {
		return err
	}
	clientRoots, err := roots("WEAVER_CONTROL_CLIENT_CA")
	if err != nil {
		return err
	}
	leaf, err := digest("WEAVER_CONTROL_PEER_SHA256")
	if err != nil {
		return err
	}
	token, err := digest("WEAVER_CONTROL_TOKEN_SHA256")
	if err != nil {
		return err
	}
	address, err := required("WEAVER_CONTROL_LISTEN")
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}
	bounded := BoundListener(listener)
	defer bounded.Close()
	input, err := selectDeploymentSource(os.LookupEnv)
	if err != nil {
		return err
	}
	if input.producer == "" {
		data, err := readBoundFile(input.path)
		if err != nil {
			return err
		}
		format := config.ProfileJSON
		if ext := strings.ToLower(filepath.Ext(input.path)); ext == ".yaml" || ext == ".yml" {
			format = config.ProfileYAML
		}
		input.bundle, err = config.DecodeBundle(data, format)
		if err != nil {
			return err
		}
	}
	trace("configuration-ready")
	authorityRoots, err := roots("WEAVER_CONTROL_AUTHORITY_CA")
	if err != nil {
		return err
	}
	opKey, err := pair("WEAVER_CONTROL_AUTHORITY_OPERATION")
	if err != nil {
		return err
	}
	relayMode := os.Getenv("WEAVER_CONTROL_PROVIDER_OAUTH_RELAY")
	if relayMode != "" && relayMode != "1" {
		return errors.New("invalid provider OAuth relay mode")
	}
	oauthRelay := relayMode == "1"
	if oauthRelay && sha256.Sum256(opKey.Certificate[0]) == leaf {
		return errors.New("OAuth relay requires distinct ingress and authority certificates")
	}
	sourceKey, err := pair("WEAVER_CONTROL_AUTHORITY_SOURCE")
	if err != nil {
		return err
	}
	opToken, err := required("WEAVER_CONTROL_AUTHORITY_OPERATION_TOKEN")
	if err != nil {
		return err
	}
	sourceToken, err := required("WEAVER_CONTROL_AUTHORITY_SOURCE_TOKEN")
	if err != nil {
		return err
	}
	opAddress, err := required("WEAVER_CONTROL_AUTHORITY_OPERATION_ADDRESS")
	if err != nil {
		return err
	}
	sourceAddress, err := required("WEAVER_CONTROL_AUTHORITY_SOURCE_ADDRESS")
	if err != nil {
		return err
	}
	name, err := required("WEAVER_CONTROL_AUTHORITY_SERVER_NAME")
	if err != nil {
		return err
	}
	operation, err := gatewayclient.Dial(startup, opAddress, opToken, &tls.Config{RootCAs: authorityRoots, Certificates: []tls.Certificate{opKey}, ServerName: name})
	if err != nil {
		return err
	}
	defer operation.Connection.Close()
	trace("operation-channel-connected")
	source, err := gatewayclient.Dial(startup, sourceAddress, sourceToken, &tls.Config{RootCAs: authorityRoots, Certificates: []tls.Certificate{sourceKey}, ServerName: name})
	if err != nil {
		return err
	}
	defer source.Connection.Close()
	trace("source-channel-connected")
	gateway, err := input.bootstrap(startup, source, operation, trace)
	if err != nil {
		return err
	}
	// Static published routing has no runtime source reads. Return its scarce
	// authenticated connection after known activation, before serving ingress.
	// A deferred catalogue keeps source custody; bootstrap errors return above.
	if gateway.source == nil {
		if err := source.Connection.Close(); err != nil {
			return err
		}
		trace("bootstrap-source-channel-closed")
	}
	gateway.oauthRelay = oauthRelay
	trace("authority-reconciled")
	server, err := NewServer(gateway, &tls.Config{Certificates: []tls.Certificate{serverKey}, ClientCAs: clientRoots, ClientAuth: tls.RequireAndVerifyClientCert}, leaf, token)
	if err != nil {
		return err
	}
	serving := make(chan error, 1)
	trace("serve-starting")
	go func() { serving <- server.Serve(bounded) }()
	select {
	case err := <-serving:
		return err
	case <-ctx.Done():
	}
	drained := make(chan struct{})
	go func() { server.GracefulStop(); close(drained) }()
	select {
	case <-drained:
		err := <-serving
		if errors.Is(err, grpc.ErrServerStopped) {
			return nil
		}
		return err
	case <-time.After(15 * time.Second):
		server.Stop()
		<-drained
		<-serving
		return errors.New("control drain exceeded bound")
	}
}
