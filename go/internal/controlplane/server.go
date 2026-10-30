package controlplane

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"errors"
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
	"net"
	"strings"
	"sync"
	"time"
)

func NewServer(gateway *Gateway, security *tls.Config, leaf, token [32]byte) (*grpc.Server, error) {
	if gateway == nil || security == nil || security.ClientAuth != tls.RequireAndVerifyClientCert || security.ClientCAs == nil || len(security.Certificates) == 0 {
		return nil, errors.New("explicit control-plane mutual TLS required")
	}
	tlsSettings := security.Clone()
	tlsSettings.MinVersion = tls.VersionTLS13
	lane := make(chan struct{}, 16)
	auth := func(ctx context.Context) (func(), error) {
		p, ok := peer.FromContext(ctx)
		if !ok {
			return nil, status.Error(codes.Unauthenticated, "peer required")
		}
		identity, ok := p.AuthInfo.(credentials.TLSInfo)
		if !ok || len(identity.State.VerifiedChains) == 0 || len(identity.State.PeerCertificates) == 0 {
			return nil, status.Error(codes.Unauthenticated, "verified peer required")
		}
		digest := sha256.Sum256(identity.State.PeerCertificates[0].Raw)
		md, _ := metadata.FromIncomingContext(ctx)
		values := md.Get("authorization")
		if len(values) != 1 || len(values[0]) > 1024 || !strings.HasPrefix(values[0], "Bearer ") {
			return nil, status.Error(codes.Unauthenticated, "credential required")
		}
		provided := sha256.Sum256([]byte(strings.TrimPrefix(values[0], "Bearer ")))
		if subtle.ConstantTimeCompare(digest[:], leaf[:]) != 1 || subtle.ConstantTimeCompare(provided[:], token[:]) != 1 {
			return nil, status.Error(codes.PermissionDenied, "caller rejected")
		}
		select {
		case lane <- struct{}{}:
			return func() { <-lane }, nil
		default:
			return nil, status.Error(codes.ResourceExhausted, "control admission full")
		}
	}
	server := grpc.NewServer(grpc.Creds(credentials.NewTLS(tlsSettings)), grpc.MaxRecvMsgSize(2<<20), grpc.MaxSendMsgSize(4<<20), grpc.MaxConcurrentStreams(8), grpc.MaxHeaderListSize(16<<10), grpc.ConnectionTimeout(2*time.Second),
		grpc.UnaryInterceptor(func(ctx context.Context, req any, info *grpc.UnaryServerInfo, next grpc.UnaryHandler) (any, error) {
			release, err := auth(ctx)
			if err != nil {
				return nil, err
			}
			defer release()
			return next(ctx, req)
		}),
		grpc.StreamInterceptor(func(service any, stream grpc.ServerStream, info *grpc.StreamServerInfo, next grpc.StreamHandler) error {
			release, err := auth(stream.Context())
			if err != nil {
				return err
			}
			defer release()
			return next(service, stream)
		}))
	pb.RegisterGatewayServer(server, gateway)
	return server, nil
}

// BoundListener retains each slot through actual socket Close, including TLS setup.
func BoundListener(listener net.Listener) net.Listener {
	return &boundedListener{Listener: listener, slots: make(chan struct{}, 32), closed: make(chan struct{})}
}

type boundedListener struct {
	net.Listener
	slots  chan struct{}
	closed chan struct{}
	once   sync.Once
}

func (l *boundedListener) Accept() (net.Conn, error) {
	select {
	case l.slots <- struct{}{}:
	case <-l.closed:
		return nil, net.ErrClosed
	}
	c, err := l.Listener.Accept()
	if err != nil {
		<-l.slots
		return nil, err
	}
	return &boundedConnection{Conn: c, release: func() { <-l.slots }}, nil
}
func (l *boundedListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return l.Listener.Close()
}

type boundedConnection struct {
	net.Conn
	once    sync.Once
	release func()
}

func (c *boundedConnection) Close() error { err := c.Conn.Close(); c.once.Do(c.release); return err }
