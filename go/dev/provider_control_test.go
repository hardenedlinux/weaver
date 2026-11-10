// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && !windows

package dev

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"gopkg.in/yaml.v3"
)

func controlBundle(t testing.TB, f *fixture) config.Bundle {
	t.Helper()
	p := f.plan
	p.Family, p.Revision, p.Fence = "control", 1, 2
	task := profileTask(t, p, *providerProfile())
	next := p
	next.Node = "next"
	digest, err := next.Digest()
	if err != nil {
		t.Fatal(err)
	}
	task.Nodes = append(task.Nodes, "next")
	task.BodyDigests["next"] = task.BodyDigests[p.Node]
	task.StreamContracts["next"] = digest
	task.NodeCostBounds["next"] = 4
	parent := uint64(0)
	policy := f.policy + `
permit(principal == Weaver::Principal::"alice", action in [Weaver::Action::"admitProvider", Weaver::Action::"invokeProvider", Weaver::Action::"emitProvider"], resource)
when { context.family == "control" && ["infer", "next"].contains(context.node) && context.profile == "p" && context.model == "model-a" && context.profile_digest != "" && context.protocol == "openai.chat-text-sse.v1" && context.output_token_limit <= 4096 && context.message_count <= 64 && context.sequence < 4096 && ["protobuf", "arrow"].contains(context.format) };`
	bundle := config.Bundle{Governance: config.Governance{Schema: "agentic-ai-lab.loop-governor.v1", Family: "control", OpenNodes: []string{"infer", "next"}}, Tasks: []v1.Task{task}, Plans: []v1.ProviderPlan{p, next}, Publication: v1.Publication{OperationID: "control-activation", ExpectedRevision: &parent, Fence: 2, Policy: policy, Schema: f.schema}}
	if err := bundle.Validate(); err != nil {
		t.Fatal(err)
	}
	return bundle
}

type controlProcess struct {
	fixture               *fixture
	ingress               *testPKI
	env                   []string
	address, directory    string
	child                 *exec.Cmd
	exited                chan error
	client                *gatewayclient.Client
	heapInput, heapOutput *os.File
	image                 string
}

func newControlProcess(t testing.TB, f *fixture, path string) *controlProcess {
	t.Helper()
	d := t.TempDir()
	sourceKey, err := x509.MarshalPKCS8PrivateKey(f.pki.source.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	files := map[string][]byte{"server": f.pki.serverPEM, "server-key": f.pki.serverKey, "ca": f.pki.ca, "operation": f.pki.clientPEM, "operation-key": f.pki.clientKey, "source": pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: f.pki.source.Certificate[0]}), "source-key": pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: sourceKey})}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(d, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := l.Addr().String()
	l.Close()
	leaf, token := sha256.Sum256(f.pki.client.Certificate[0]), sha256.Sum256([]byte(ownerToken))
	settings := map[string]string{"CONFIG": path, "SERVER_CERT": filepath.Join(d, "server"), "SERVER_KEY": filepath.Join(d, "server-key"), "CLIENT_CA": filepath.Join(d, "ca"), "PEER_SHA256": hex.EncodeToString(leaf[:]), "TOKEN_SHA256": hex.EncodeToString(token[:]), "LISTEN": address,
		"AUTHORITY_CA": filepath.Join(d, "ca"), "AUTHORITY_OPERATION_CERT": filepath.Join(d, "operation"), "AUTHORITY_OPERATION_KEY": filepath.Join(d, "operation-key"), "AUTHORITY_SOURCE_CERT": filepath.Join(d, "source"), "AUTHORITY_SOURCE_KEY": filepath.Join(d, "source-key"), "AUTHORITY_OPERATION_TOKEN": ownerToken, "AUTHORITY_SOURCE_TOKEN": adminToken, "AUTHORITY_OPERATION_ADDRESS": f.address, "AUTHORITY_SOURCE_ADDRESS": f.sourceAddress, "AUTHORITY_SERVER_NAME": "localhost"}
	c := &controlProcess{fixture: f, address: address, directory: d, image: controlBinary}
	for name, value := range settings {
		c.env = append(c.env, "WEAVER_CONTROL_"+name+"="+value)
	}
	// Measure the service drain and process exit without the race runtime's
	// default one-second sleep after main returns. Keep all race checks active.
	c.env = append(c.env, "GORACE="+strings.TrimSpace(os.Getenv("GORACE")+" atexit_sleep_ms=0"))
	t.Cleanup(func() { c.stop(t) })
	return c
}
func (c *controlProcess) start(t testing.TB) {
	t.Helper()
	log, err := os.OpenFile(filepath.Join(c.directory, "control.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	previousLog, err := log.Stat()
	if err != nil {
		log.Close()
		t.Fatal(err)
	}
	child := exec.Command(c.image)
	child.Env = append(os.Environ(), c.env...)
	child.Stdout, child.Stderr = log, log
	if os.Getenv("WEAVER_TEST_CONTROL_HEAP") == "1" {
		if os.Getenv("WEAVER_TEST_CONTROL_PROFILE_ROOT") != "" {
			child.Env = append(child.Env, "WEAVER_TEST_CONTROL_PROFILE_DIR="+c.directory)
		}
		input, err := child.StdinPipe()
		if err != nil {
			log.Close()
			t.Fatal(err)
		}
		child.Stdout = nil
		output, err := child.StdoutPipe()
		if err != nil {
			input.Close()
			log.Close()
			t.Fatal(err)
		}
		c.heapInput, c.heapOutput = input.(*os.File), output.(*os.File)
	}
	if err := child.Start(); err != nil {
		log.Close()
		t.Fatal(err)
	}
	c.child = child
	c.exited = make(chan error, 1)
	exited := c.exited
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	go func() {
		err := child.Wait()
		log.Close()
		exited <- err
		cancel()
	}()
	caller := c.fixture.pki.client
	if c.ingress != nil {
		caller = c.ingress.client
	}
	c.client, err = gatewayclient.Dial(ctx, c.address, ownerToken, &tls.Config{RootCAs: c.fixture.pki.root, Certificates: []tls.Certificate{caller}, ServerName: "localhost", MinVersion: tls.VersionTLS13})
	if err != nil {
		c.stop(t)
		data, _ := os.ReadFile(filepath.Join(c.directory, "control.log"))
		t.Fatalf("control readiness: %v: %s", err, data)
	}
	// Preserve phase observations in the native test report, not persistent logs.
	// These unauthenticated diagnostics never replace readiness or exit checks.
	data, err := os.ReadFile(filepath.Join(c.directory, "control.log"))
	if err != nil {
		t.Fatal(err)
	}
	if previousLog.Size() > int64(len(data)) {
		t.Fatal("control phase log was truncated during startup")
	}
	for _, line := range strings.Split(string(data[previousLog.Size():]), "\n") {
		if strings.HasPrefix(line, "weaver scheme phase=") || strings.Contains(line, "Control startup") {
			t.Log(line)
		}
	}
}

func (c *controlProcess) useProducer(name string) {
	if name == "" {
		return
	}
	var environment []string
	for _, value := range c.env {
		if !strings.HasPrefix(value, "WEAVER_CONTROL_CONFIG=") {
			environment = append(environment, value)
		}
	}
	c.env = append(environment, "WEAVER_CONTROL_PRODUCER="+name)
}
func (c *controlProcess) stop(t testing.TB) {
	t.Helper()
	if c.child == nil {
		return
	}
	if c.client != nil {
		c.client.Connection.Close()
	}
	c.child.Process.Signal(syscall.SIGTERM)
	select {
	case err := <-c.exited:
		if err != nil {
			data, _ := os.ReadFile(filepath.Join(c.directory, "control.log"))
			t.Errorf("control natural exit: %v: %s", err, data)
		}
	case <-time.After(15 * time.Second):
		c.child.Process.Kill()
		<-c.exited
		t.Error("control cleanup kill is a failure")
	}
	c.child = nil
}

func writeControlBundle(t testing.TB, f *fixture, b config.Bundle, format string) string {
	t.Helper()
	if b.Publication.Review == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		reviewer, ok := f.admin.RPC.(*fixtureReviewer)
		if !ok {
			t.Fatal("independent fixture reviewer missing")
		}
		reviewed, err := reviewer.review(f.admin.Context(ctx), b.Publication)
		if err != nil {
			t.Fatal(err)
		}
		b.Publication.Review = reviewed
	}
	data, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	if format == "yaml" {
		var value any
		if err = yaml.Unmarshal(data, &value); err != nil {
			t.Fatal(err)
		}
		data, err = yaml.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(f.directory, "control."+format)
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func exerciseControl(t *testing.T, format string, source func(*testing.T, *fixture, config.Bundle) string) {
	exerciseControlPolicies(t, format, source, controlPolicySources{})
}

type controlPolicySources struct {
	initial, revoked, producer string
	configure                  func(*testing.T, *fixture, config.Bundle)
}

func exerciseControlPolicies(t *testing.T, format string, source func(*testing.T, *fixture, config.Bundle) string, policies controlPolicySources) {
	t.Helper()
	allowTail := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(allowTail) }) }
	defer unblock()
	f := newFixture(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		emitChunk(w, "prefix", false)
		select {
		case <-allowTail:
			emitChunk(w, "forbidden-tail", false)
			emitChunk(w, "", true)
			fmt.Fprint(w, "data: [DONE]\n\n")
		case <-r.Context().Done():
		}
	}, false)
	bundle := controlBundle(t, f)
	if policies.initial != "" {
		bundle.Publication.Policy = policies.initial
	}
	path := writeControlBundle(t, f, bundle, format)
	if source != nil {
		path = source(t, f, bundle)
	}
	if policies.configure != nil {
		policies.configure(t, f, bundle)
	}
	c := newControlProcess(t, f, path)
	c.useProducer(policies.producer)
	c.start(t)
	parent := uint64(1)
	revocation := v1.Publication{OperationID: "control-revoke", ExpectedRevision: &parent, Fence: 3, Policy: `forbid(principal,action,resource);`, Schema: f.schema}
	if policies.revoked != "" {
		revocation.Policy = policies.revoked
	}
	if source != nil {
		revoked := bundle
		revoked.Publication = revocation
		// Compile prospective revocation before starting the bounded stream RPC.
		// No source publication or provider send occurs during compilation.
		revocation = preparedControlBundle(t, source(t, f, revoked)).Publication
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("source activation executed provider")
	}
	if _, err := c.client.RPC.Inspect(ctx, &pb.OperationKey{Family: "control", Node: "infer"}); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("missing frontend credential admitted: %v", err)
	}
	// Shared Kubernetes names and a valid bearer do not identify the pinned caller.
	wrong, err := gatewayclient.Dial(ctx, c.address, ownerToken, &tls.Config{RootCAs: f.pki.root, Certificates: []tls.Certificate{secondaryClient(t, f.pki)}, ServerName: "localhost", MinVersion: tls.VersionTLS13})
	if err != nil {
		t.Fatal(err)
	}
	_, err = wrong.RPC.Inspect(wrong.Context(ctx), &pb.OperationKey{Family: "control", Node: "infer"})
	wrong.Connection.Close()
	if status.Code(err) != codes.PermissionDenied {
		t.Fatalf("same-name peer admitted: %v", err)
	}
	if _, err = c.client.RPC.PublishAuthority(c.client.Context(ctx), gatewayclient.Publication(bundle.Publication)); status.Code(err) != codes.Unimplemented {
		t.Fatalf("frontend exposes source publication: %v", err)
	}
	if _, err = c.client.RPC.RegisterTask(c.client.Context(ctx), &pb.RegisterTaskRequest{Task: gatewayclient.Task(bundle.Tasks[0])}); status.Code(err) != codes.Unimplemented {
		t.Fatalf("frontend exposes registration: %v", err)
	}
	if _, err = c.client.RPC.RegisterPublishedTask(c.client.Context(ctx), &pb.RegisterPublishedTaskRequest{Task: gatewayclient.Task(bundle.Tasks[0])}); status.Code(err) != codes.Unimplemented {
		t.Fatalf("frontend exposes publication-bound registration: %v", err)
	}
	wrongPlan := bundle.Plans[0]
	wrongPlan.Body = strings.Replace(wrongPlan.Body, "hello", "forged", 1)
	if _, err = c.client.Execute(ctx, wrongPlan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("changed source body admitted")
	}
	wrongPlan = bundle.Plans[0]
	wrongPlan.Routes = append([]v1.ProviderRoute(nil), wrongPlan.Routes...)
	wrongPlan.Routes[0], wrongPlan.Routes[2] = wrongPlan.Routes[2], wrongPlan.Routes[0]
	if _, err = c.client.Execute(ctx, wrongPlan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("route order changed")
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 || f.denied.Load() != 0 {
		t.Fatal("invalid proposal reached provider")
	}
	var prefix bool
	encoding := pb.Encoding_PROTOBUF
	if format == "yaml" {
		encoding = pb.Encoding_ARROW_IPC
	}
	_, err = c.client.Execute(ctx, bundle.Plans[0], encoding, 1, func(event *pb.Event) error {
		if strings.Contains(event.GetText(), "forbidden-tail") {
			t.Error("revoked output escaped")
		}
		if !prefix && event.GetText() == "prefix" {
			prefix = true
			_, e := f.admin.Publish(ctx, revocation)
			unblock()
			return e
		}
		return nil
	})
	if !prefix || err == nil {
		t.Fatalf("partial/revoke boundary prefix=%v err=%v", prefix, err)
	}
	observed, err := c.client.RPC.Inspect(c.client.Context(ctx), &pb.OperationKey{Family: "control", Node: "infer"})
	if err != nil || observed.GetHeld() != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatalf("unknown hold: %v %v calls=%d", observed, err, f.primary.Load())
	}
	// Restart both processes. Exact publication replay observes its original outcome,
	// but must not overwrite the newer revocation or recreate an execution root.
	cancel()
	c.stop(t)
	f.stop(t)
	f.start(t)
	c.start(t)
	ctx, cancel = context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	for _, p := range bundle.Plans {
		if _, err = c.client.Execute(ctx, p, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { t.Error("post-restart output"); return nil }); status.Code(err) != codes.FailedPrecondition {
			t.Fatal("historical publication became current authority")
		}
	}
	observed, err = c.client.RPC.Inspect(c.client.Context(ctx), &pb.OperationKey{Family: "control", Node: "infer"})
	if err != nil || observed.GetHeld() != 4 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatalf("restart duplicated/refunded original: %v %v", observed, err)
	}
	t.Log("Governor source handoff -> source publication -> mTLS control -> Rust partial send -> revoke -> dual restart: original hold retained")
}

func TestProviderControlJSONYAMLRevocationAndRestart(t *testing.T) {
	for _, format := range []string{"json", "yaml"} {
		t.Run(format, func(t *testing.T) { exerciseControl(t, format, nil) })
	}
}

func TestProviderControlCompleteStreamsShareBudgetAndRejectSDKRetry(t *testing.T) {
	exerciseControlSharedBudget(t, nil)
}

func exerciseControlSharedBudget(t *testing.T, source func(*testing.T, *fixture, config.Bundle) string) {
	exerciseControlSharedBudgetPolicies(t, source, controlPolicySources{})
}

func exerciseControlSharedBudgetPolicies(t *testing.T, source func(*testing.T, *fixture, config.Bundle) string, policies controlPolicySources) {
	t.Helper()
	f := newFixture(t, completeSSE, false)
	bundle := controlBundle(t, f)
	bundle.Tasks[0].Budget = 4
	path := writeControlBundle(t, f, bundle, "json")
	if source != nil {
		path = source(t, f, bundle)
	}
	if policies.configure != nil {
		policies.configure(t, f, bundle)
	}
	c := newControlProcess(t, f, path)
	c.useProducer(policies.producer)
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	type result struct {
		receipt *pb.ProviderReceipt
		err     error
		rows    int
	}
	results := make(chan result, 2)
	for i, p := range bundle.Plans {
		go func(i int, p v1.ProviderPlan) {
			rows := 0
			receipt, err := c.client.Execute(ctx, p, pb.Encoding(i), 1, func(*pb.Event) error { rows++; return nil })
			results <- result{receipt, err, rows}
		}(i, p)
	}
	success := 0
	for range 2 {
		r := <-results
		if r.err == nil {
			success++
			if r.receipt.GetHeld() != 4 || r.rows == 0 {
				t.Fatal("missing canonical completed receipt", r.receipt, r.rows)
			}
		}
	}
	if success != 1 || f.primary.Load() != 1 || f.backup.Load() != 0 {
		t.Fatalf("shared budget duplicated sends: success=%d calls=%d", success, f.primary.Load())
	}
	for _, p := range bundle.Plans {
		if _, err := c.client.Execute(ctx, p, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
			t.Fatal("SDK retry bypassed spent claim or shared hold")
		}
	}
	if f.primary.Load() != 1 {
		t.Fatal("SDK retry sent again")
	}
}

// Reuse the native publication reply-loss relay and its per-call counter.
func (p *publicationReplyLoss) RegisterTask(ctx context.Context, in *pb.RegisterTaskRequest) (*pb.Empty, error) {
	source := p.sourceClient()
	return source.RPC.RegisterTask(source.Context(ctx), in)
}
func (p *publicationReplyLoss) CompileSource(ctx context.Context, in *pb.ProducerRequest) (*pb.CompiledSource, error) {
	source := p.sourceClient()
	return source.RPC.CompileSource(source.Context(ctx), in)
}
func (p *publicationReplyLoss) RegisterPublishedTask(ctx context.Context, in *pb.RegisterPublishedTaskRequest) (*pb.Empty, error) {
	source := p.sourceClient()
	return source.RPC.RegisterPublishedTask(source.Context(ctx), in)
}
func (p *publicationReplyLoss) StageAuthority(ctx context.Context, in *pb.PublishRequest) (*pb.PublicationKey, error) {
	source := p.sourceClient()
	key, err := source.RPC.StageAuthority(source.Context(ctx), in)
	if err != nil {
		return nil, err
	}
	if p.stages.Add(1) == 1 && p.loseStage {
		return nil, status.Error(codes.Unavailable, "injected reply loss after durable staging")
	}
	return key, nil
}
func TestProviderControlPublicationReplyLossCannotActivateOrRebase(t *testing.T) {
	exerciseControlPublicationReplyLoss(t, nil)
}

func preparedControlBundle(t testing.TB, path string) config.Bundle {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	bundle, err := config.DecodeBundle(data, config.ProfileJSON)
	if err != nil {
		t.Fatal(err)
	}
	return bundle
}

func exerciseControlPublicationReplyLoss(t *testing.T, source func(*testing.T, *fixture, config.Bundle) string) {
	exerciseControlSourceReplyLoss(t, source, false, controlPolicySources{})
}

func TestProviderControlStagingReplyLossCannotActivateOrLosePending(t *testing.T) {
	exerciseControlSourceReplyLoss(t, nil, true, controlPolicySources{})
}

func exerciseControlSourceReplyLoss(t *testing.T, source func(*testing.T, *fixture, config.Bundle) string, loseStage bool, policies controlPolicySources) {
	t.Helper()
	f := newFixture(t, completeSSE, false)
	bundle := controlBundle(t, f)
	path := writeControlBundle(t, f, bundle, "json")
	if source != nil {
		path = source(t, f, bundle)
	}
	if policies.configure != nil {
		policies.configure(t, f, bundle)
	}
	c := newControlProcess(t, f, path)
	c.useProducer(policies.producer)
	certificate, err := tls.X509KeyPair(f.pki.serverPEM, f.pki.serverKey)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer(grpc.Creds(credentials.NewTLS(&tls.Config{Certificates: []tls.Certificate{certificate}, ClientCAs: f.pki.root, ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS13})))
	proxy := &publicationReplyLoss{source: f.admin, loseStage: loseStage}
	pb.RegisterGatewayServer(server, proxy)
	exited := make(chan error, 1)
	go func() { exited <- server.Serve(listener) }()
	t.Cleanup(func() { server.Stop(); <-exited })
	c.env = append(c.env, "WEAVER_CONTROL_AUTHORITY_SOURCE_ADDRESS="+listener.Addr().String())
	child := exec.Command(controlBinary)
	child.Env = append(os.Environ(), c.env...)
	log, err := os.Create(filepath.Join(c.directory, "lost-publication.log"))
	if err != nil {
		t.Fatal(err)
	}
	child.Stdout, child.Stderr = log, log
	if err = child.Start(); err != nil {
		log.Close()
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- child.Wait() }()
	select {
	case err = <-done:
		if err == nil {
			t.Error("ambiguous publication activated service")
		}
	case <-time.After(15 * time.Second):
		child.Process.Kill()
		<-done
		data, readErr := os.ReadFile(filepath.Join(c.directory, "lost-publication.log"))
		if len(data) > 8192 {
			data = data[len(data)-8192:]
		}
		t.Errorf("failed bootstrap did not exit naturally: inspect=%d stage=%d final=%d log-error=%v log=%s", proxy.inspections.Load(), proxy.stages.Load(), proxy.calls.Load(), readErr, data)
	}
	log.Close()
	writes := int64(1)
	if loseStage {
		writes = 0
	}
	views := int64(0)
	if policies.producer != "" {
		views = 1
	}
	if proxy.calls.Load() != writes || proxy.inspections.Load() != 1 || proxy.stages.Load() != 1 || proxy.sourceViews.Load() != views {
		data, readErr := os.ReadFile(filepath.Join(c.directory, "lost-publication.log"))
		t.Fatalf("source protocol count mismatch: authority=%d inspect=%d stage=%d final=%d; expected authority=%d inspect=1 stage=1 final=%d (missing calls do not establish retry); log-error=%v log=%s", proxy.sourceViews.Load(), proxy.inspections.Load(), proxy.stages.Load(), proxy.calls.Load(), views, writes, readErr, data)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	r, err := f.admin.InspectPublication(ctx, bundle.Publication)
	if (!loseStage && (err != nil || r.GetOutcome() != pb.PublicationOutcome_COMMITTED)) ||
		(loseStage && status.Code(err) != codes.NotFound) || f.primary.Load() != 0 {
		t.Fatal("lost reply changed committed outcome or sent", r, err)
	}
	connection, err := net.DialTimeout("tcp", c.address, 100*time.Millisecond)
	if err == nil {
		connection.Close()
		t.Fatal("unknown outcome left ingress active")
	}
	// Exact recovery observes the original committed outcome without publishing
	// another generation. Registration replay retains the original source task.
	cancel()
	f.stop(t)
	f.start(t)
	proxy.replaceSource(f.admin)
	c.start(t)
	ctx, cancel = context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if _, err = c.client.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err != nil {
		t.Fatal("exact outcome recovery", err)
	}
	if f.primary.Load() != 1 {
		t.Fatal("recovery duplicated provider send")
	}
	if proxy.calls.Load() != 1 || proxy.inspections.Load() != 2 || proxy.sourceViews.Load() != 2*views {
		t.Fatalf("recovery changed source protocol: authority=%d inspect=%d final=%d", proxy.sourceViews.Load(), proxy.inspections.Load(), proxy.calls.Load())
	}
	key := &pb.OperationKey{Family: bundle.Plans[0].Family, Node: bundle.Plans[0].Node}
	before, err := c.client.RPC.Inspect(c.client.Context(ctx), key)
	if err != nil {
		t.Fatal(err)
	}
	c.stop(t)
	f.stop(t)
	f.start(t)
	proxy.replaceSource(f.admin)
	c.start(t)
	cancel()
	ctx, cancel = context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if _, err := c.client.Execute(ctx, bundle.Plans[0], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("dual restart reopened the consumed claim")
	}
	after, err := c.client.RPC.Inspect(c.client.Context(ctx), key)
	if err != nil || !proto.Equal(before, after) || f.primary.Load() != 1 || proxy.calls.Load() != 1 || proxy.inspections.Load() != 3 || proxy.sourceViews.Load() != 3*views {
		t.Fatal("observed recovery changed original accounting or submitted publication", err)
	}
	c.stop(t)
	parent := bundle.View().Revision
	revocation := bundle.Publication
	revocation.OperationID = "post-recovery-revocation"
	revocation.ExpectedRevision = &parent
	revocation.Fence++
	revocation.Policy = "forbid(principal,action,resource);"
	if _, err := f.admin.Publish(ctx, revocation); err != nil {
		t.Fatal(err)
	}
	f.stop(t)
	f.start(t)
	proxy.replaceSource(f.admin)
	c.start(t)
	cancel()
	ctx, cancel = context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if _, err := c.client.Execute(ctx, bundle.Plans[1], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err == nil {
		t.Fatal("historical receipt overrode later revocation")
	}
	if f.primary.Load() != 1 || f.backup.Load() != 0 || proxy.calls.Load() != 1 || proxy.inspections.Load() != 4 {
		t.Fatal("historical recovery sent or republished")
	}
}

// Forward independently produced evidence through the existing lost-reply relay.
// This method neither issues a review nor changes publication reply-loss counts.
func (p *publicationReplyLoss) RegisterPublicationReview(ctx context.Context, in *pb.DeltaReview) (*pb.ReviewRegistrationReceipt, error) {
	source := p.sourceClient()
	return source.RPC.RegisterPublicationReview(source.Context(ctx), in)
}
