//go:build integration && !windows

package dev

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"github.com/HardenedLinux/weaver/go/internal/routing"
)

const ownerToken = "test-agent-operation-token"
const adminToken = "test-source-publisher-token"

var serverBinary string
var controlBinary string

func TestMain(m *testing.M) {
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		os.Exit(1)
	}
	repo := filepath.Clean(filepath.Join(filepath.Dir(source), "../.."))
	cmd := exec.Command("cargo", "build", "-p", "weaver-server", "--features", providerRuntimeFeatures, "--locked", "--offline")
	cmd.Dir = repo
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	directory, err := os.MkdirTemp("", "weaver-control-build-*")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	serverBinary = filepath.Join(directory, "weaver-server")
	digest, err := publishProviderImage(filepath.Join(repo, "target/debug/weaver-server"), serverBinary)
	if err != nil {
		os.RemoveAll(directory)
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Fprintln(os.Stderr, "test-owned provider image sha256="+digest)
	controlBinary = filepath.Join(directory, "weaver-control")
	controlBuild := exec.Command(filepath.Join(runtime.GOROOT(), "bin/go"), "-C", "go", "build", "-race", "-o", controlBinary, "./cmd/weaver-control")
	controlBuild.Dir, controlBuild.Stdout, controlBuild.Stderr = repo, os.Stderr, os.Stderr
	if err := controlBuild.Run(); err != nil {
		os.RemoveAll(directory)
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	result := m.Run()
	os.RemoveAll(directory)
	os.Exit(result)
}

type testPKI struct {
	ca, key, serverPEM, serverKey, clientPEM, clientKey []byte
	root                                                *x509.CertPool
	client                                              tls.Certificate
	source                                              tls.Certificate
}

func pki(t testing.TB) *testPKI {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test-ca"}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature}
	der, err := x509.CreateCertificate(rand.Reader, ca, ca, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	parsed, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	issue := func(serial int64, client bool) ([]byte, []byte) {
		leaf, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		cert := &x509.Certificate{SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: "shared-kubernetes-identity"}, DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1)}, NotBefore: ca.NotBefore, NotAfter: ca.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
		if client {
			cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
		}
		signed, err := x509.CreateCertificate(rand.Reader, cert, parsed, &leaf.PublicKey, key)
		if err != nil {
			t.Fatal(err)
		}
		private, err := x509.MarshalPKCS8PrivateKey(leaf)
		if err != nil {
			t.Fatal(err)
		}
		return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: signed}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private})
	}
	server, serverKey := issue(2, false)
	client, clientKey := issue(3, true)
	source, sourceKey := issue(6, true)
	sourcePair, err := tls.X509KeyPair(source, sourceKey)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.X509KeyPair(client, clientKey)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(caPEM)
	caKey, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return &testPKI{ca: caPEM, key: caKey, serverPEM: server, serverKey: serverKey, clientPEM: client, clientKey: clientKey, root: roots, client: pair, source: sourcePair}
}

type fixture struct {
	directory, address, sourceAddress string
	binary                            string
	pki                               *testPKI
	env                               []string
	child                             *exec.Cmd
	arguments                         []string
	exited                            chan error
	client, admin                     *gatewayclient.Client
	plan                              v1.ProviderPlan
	primary, backup, denied           atomic.Int64
	policy, schema                    string
}

func newFixture(t testing.TB, handler http.HandlerFunc, large bool) *fixture {
	return fixtureWithBinary(t, handler, large, serverBinary)
}
func providerProfile() *v1.ProviderProfile {
	return &v1.ProviderProfile{ID: "p", Protocol: v1.ChatTextSSE, MaxOutputTokens: 4096, MaxMessages: 64, MaxBodyBytes: 1 << 20}
}
func fixtureWithBinary(t testing.TB, handler http.HandlerFunc, large bool, binary string) *fixture {
	return fixtureWithInvocation(t, handler, large, binary, nil, nil)
}
func fixtureWithInvocation(t testing.TB, handler http.HandlerFunc, large bool, binary string, arguments, extraEnvironment []string) *fixture {
	t.Helper()
	f := &fixture{directory: t.TempDir(), pki: pki(t), binary: binary, arguments: append([]string(nil), arguments...)}
	certificate, err := tls.X509KeyPair(f.pki.serverPEM, f.pki.serverKey)
	if err != nil {
		t.Fatal(err)
	}
	upstream := func(count *atomic.Int64, h http.HandlerFunc) string {
		server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			count.Add(1)
			if r.Header.Get("Authorization") != "Bearer test-provider-key" {
				t.Error("provider credential mismatch")
			}
			h(w, r)
		}))
		server.TLS = &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12}
		server.StartTLS()
		t.Cleanup(server.Close)
		return server.URL + "/v1/chat/completions"
	}
	primary := upstream(&f.primary, handler)
	backup := upstream(&f.backup, completeSSE)
	denied := upstream(&f.denied, completeSSE)
	body := `{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":32}`
	f.plan = v1.ProviderPlan{Family: "f", Node: "infer", Profile: "p", Model: "model-a", Body: body, Ceiling: 4, Revision: 0, Fence: 1, Routes: []v1.ProviderRoute{{Target: "missing", Endpoint: "https://missing.invalid/v1/chat/completions"}, {Target: "denied", Endpoint: denied}, {Target: "primary", Endpoint: primary}, {Target: "backup", Endpoint: backup}}}
	// Keep large requests inside the same fixed native request limit.
	if large {
		var request map[string]any
		json.Unmarshal([]byte(f.plan.Body), &request)
		request["messages"] = []any{map[string]any{"role": "user", "content": string(bytesOf('x', 600000))}}
		data, _ := json.Marshal(request)
		f.plan.Body = string(data)
	}
	f.plan.ProfileCommitment, _ = providerProfile().Digest()
	digest, err := f.plan.Digest()
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(f.plan.Body))
	endpoints := map[string]string{}
	targets := []string{}
	for _, route := range f.plan.Routes {
		endpoints[route.Target] = route.Endpoint
		targets = append(targets, route.Target)
	}
	task := v1.Task{ProviderProfile: providerProfile(), Family: "f", Principal: "alice", Profile: "p", Nodes: []string{"infer"}, Targets: targets, Endpoints: endpoints, BodyDigests: map[string]string{"infer": hex.EncodeToString(sum[:])}, NodeCostBounds: map[string]uint64{"infer": 4}, StreamContracts: map[string]string{"infer": digest}, Models: []string{"model-a"}, Budget: 8}
	f.plan, err = routing.CompileProvider(task, f.plan, v1.View{Revision: 0, Fence: 1})
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f.address = listener.Addr().String()
	sourceListener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		listener.Close()
		t.Fatal(err)
	}
	f.sourceAddress = sourceListener.Addr().String()
	listener.Close()
	sourceListener.Close()
	files := map[string][]byte{"server.pem": f.pki.serverPEM, "server-key.pem": f.pki.serverKey, "ca.pem": f.pki.ca}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(f.directory, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	ownerHash := sha256.Sum256([]byte(ownerToken))
	adminHash := sha256.Sum256([]byte(adminToken))
	peerHash := sha256.Sum256(f.pki.client.Certificate[0])
	f.env = []string{"WEAVER_DB=" + filepath.Join(f.directory, "owner.db"), "WEAVER_PRINCIPAL=alice", "WEAVER_LISTEN=" + f.address, "WEAVER_TOKEN_SHA256=" + hex.EncodeToString(ownerHash[:]), "WEAVER_ADMIN_TOKEN_SHA256=" + hex.EncodeToString(adminHash[:]), "WEAVER_GRPC_PEER_SHA256=" + hex.EncodeToString(peerHash[:]), "WEAVER_GRPC_CERT=" + filepath.Join(f.directory, "server.pem"), "WEAVER_GRPC_KEY=" + filepath.Join(f.directory, "server-key.pem"), "WEAVER_GRPC_CLIENT_CA=" + filepath.Join(f.directory, "ca.pem"), "WEAVER_PROVIDER_CA=" + filepath.Join(f.directory, "ca.pem"), `WEAVER_PROVIDER_CREDENTIAL_ENVS={"primary":"WEAVER_TEST_KEY","backup":"WEAVER_TEST_KEY","denied":"WEAVER_TEST_KEY"}`, "WEAVER_TEST_KEY=test-provider-key"}
	sourceHash := sha256.Sum256(f.pki.source.Certificate[0])
	f.env = append(f.env, "WEAVER_SOURCE_LISTEN="+f.sourceAddress, "WEAVER_GRPC_SOURCE_PEER_SHA256="+hex.EncodeToString(sourceHash[:]))
	f.env = append(f.env, extraEnvironment...)
	f.start(t)
	t.Cleanup(func() { f.stop(t) })
	policy, err := os.ReadFile(filepath.Join(root(t), "prod/policies/provider/provider.cedar"))
	if err != nil {
		t.Fatal(err)
	}
	f.policy = string(policy)
	schema, err := os.ReadFile(filepath.Join(root(t), "prod/policies/provider/schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	f.schema = string(schema)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if receipt, err := f.admin.RPC.PublishAuthority(f.admin.Context(ctx), &pb.PublishRequest{OperationId: "bootstrap", Fence: 1, Policy: f.policy, Schema: f.schema}); err != nil || receipt.GetOutcome() != pb.PublicationOutcome_COMMITTED {
		t.Fatal(err)
	}
	if _, err := f.admin.RPC.RegisterTask(f.admin.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(task)}); err != nil {
		t.Fatal(err)
	}
	return f
}
func bytesOf(b byte, n int) []byte {
	result := make([]byte, n)
	for i := range result {
		result[i] = b
	}
	return result
}
func (f *fixture) start(t testing.TB) {
	t.Helper()
	started := time.Now()
	log, err := os.OpenFile(filepath.Join(f.directory, "server.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	f.child = exec.Command(f.binary, f.arguments...)
	f.child.Env = append(os.Environ(), f.env...)
	f.child.Stdout = log
	f.child.Stderr = log
	if err := f.child.Start(); err != nil {
		log.Close()
		t.Fatal(err)
	}
	f.exited = make(chan error, 1)
	child, exited := f.child, f.exited
	go func() { err := child.Wait(); log.Close(); exited <- err }()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	security := &tls.Config{RootCAs: f.pki.root, Certificates: []tls.Certificate{f.pki.client}, ServerName: "localhost", MinVersion: tls.VersionTLS13}
	f.client, err = gatewayclient.Dial(ctx, f.address, ownerToken, security)
	t.Logf("Rust owner startup operation-channel started=%s elapsed=%s error=%v", started.UTC().Format(time.RFC3339Nano), time.Since(started), err)
	if err != nil {
		f.child.Process.Signal(syscall.SIGTERM)
		<-f.exited
		data, _ := os.ReadFile(filepath.Join(f.directory, "server.log"))
		t.Fatalf("gRPC startup: %v: %s", err, data)
	}
	sourceSecurity := security.Clone()
	sourceSecurity.Certificates = []tls.Certificate{f.pki.source}
	f.admin, err = gatewayclient.Dial(ctx, f.sourceAddress, adminToken, sourceSecurity)
	t.Logf("Rust owner startup source-channel elapsed=%s error=%v", time.Since(started), err)
	if err != nil {
		f.stop(t)
		t.Fatalf("source gRPC startup: %v", err)
	}
	if stages, err := os.ReadFile(filepath.Join(f.directory, "server.log")); err == nil {
		t.Logf("Rust owner startup stage observations: %s", stages)
	}
}
func (f *fixture) stop(t testing.TB) {
	t.Helper()
	if f.child == nil {
		return
	}
	f.client.Connection.Close()
	if f.admin != nil {
		f.admin.Connection.Close()
	}
	f.child.Process.Signal(syscall.SIGTERM)
	select {
	case err := <-f.exited:
		if err != nil {
			data, _ := os.ReadFile(filepath.Join(f.directory, "server.log"))
			t.Errorf("server natural exit: %v: %s", err, data)
		}
	case <-time.After(15 * time.Second):
		f.child.Process.Kill()
		<-f.exited
		t.Error("server did not exit naturally; cleanup kill is a failure")
	}
	f.child = nil
}
func emitChunk(w http.ResponseWriter, text string, finish bool) {
	var reason any
	if finish {
		reason = "stop"
	}
	data, _ := json.Marshal(map[string]any{"id": "stream-1", "object": "chat.completion.chunk", "model": "model-a", "choices": []any{map[string]any{"index": 0, "delta": map[string]any{"content": text}, "finish_reason": reason}}})
	fmt.Fprintf(w, "data: %s\n\n", data)
	w.(http.Flusher).Flush()
}
func completeSSE(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	emitChunk(w, "hello ", false)
	emitChunk(w, "world", false)
	emitChunk(w, "", true)
	fmt.Fprint(w, "data: {\"id\":\"stream-1\",\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[],\"usage\":{\"total_tokens\":7}}\n\ndata: [DONE]\n\n")
}
func secondaryClient(t testing.TB, p *testPKI) tls.Certificate {
	t.Helper()
	block, _ := pem.Decode(p.ca)
	ca, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	key, err := x509.ParseECPrivateKey(p.key)
	if err != nil {
		t.Fatal(err)
	}
	other, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{SerialNumber: big.NewInt(4), Subject: pkix.Name{CommonName: "shared-kubernetes-identity"}, NotBefore: ca.NotBefore, NotAfter: ca.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	der, err := x509.CreateCertificate(rand.Reader, cert, ca, &other.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalPKCS8PrivateKey(other)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}))
	if err != nil {
		t.Fatal(err)
	}
	return pair
}
