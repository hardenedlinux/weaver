//go:build integration

package dev

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	contract "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/streaming"
)

var rustCLI, goCLI string

func TestMain(m *testing.M) {
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		fmt.Fprintln(os.Stderr, "locate repository")
		os.Exit(1)
	}
	repo := filepath.Clean(filepath.Join(filepath.Dir(source), "../.."))
	rustCLI = filepath.Join(repo, "target/debug/weaver-cli")
	goCLI = filepath.Join(repo, "target/weaverctl")
	commands := [][]string{
		{"cargo", "build", "-p", "weaver-cli", "--locked", "--offline"},
		{filepath.Join(runtime.GOROOT(), "bin/go"), "build", "-o", goCLI, "./go/cmd/weaverctl"},
	}
	for _, args := range commands {
		command := exec.Command(args[0], args[1:]...)
		command.Dir = repo
		command.Stdout = os.Stderr
		command.Stderr = os.Stderr
		if err := command.Run(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	os.Exit(m.Run())
}
func command(t *testing.T, accepted bool, binary string, args ...string) []byte {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, args...)
	cmd.Dir = root(t)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	if ctx.Err() != nil {
		t.Fatalf("command deadline: %s %v", binary, args)
	}
	if (err == nil) != accepted {
		t.Fatalf("unexpected command outcome: %s %v: %v: %s", binary, args, err, stderr.String())
	}
	if err != nil {
		if _, ok := err.(*exec.ExitError); !ok {
			t.Fatal(err)
		}
	}
	return output
}
func native(t *testing.T, db string, accepted bool, args ...string) []byte {
	t.Helper()
	return command(t, accepted, rustCLI, append([]string{db}, args...)...)
}
func TestOriginalTaskProposalReplay(t *testing.T) {
	work := t.TempDir()
	db := filepath.Join(work, "ledger.db")
	example := filepath.Join(root(t), "examples/local-owner")
	native(t, db, true, "publish", filepath.Join(example, "permit.cedar"), "new", "1")
	native(t, db, true, "register", filepath.Join(example, "task.json"))
	proposal := command(t, true, goCLI, filepath.Join(example, "task.json"), filepath.Join(example, "request.json"), "0", "1")
	path := filepath.Join(work, "proposal.json")
	if err := os.WriteFile(path, proposal, 0600); err != nil {
		t.Fatal(err)
	}
	first := native(t, db, true, "enqueue", path)
	repeated := native(t, db, true, "enqueue", path)
	if !bytes.Equal(first, repeated) {
		t.Fatal("replay changed original receipt")
	}
	var receipt struct {
		Reserved uint64
		Outcome  string
	}
	if err := json.Unmarshal(first, &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.Reserved != 25 || receipt.Outcome != "queued" {
		t.Fatalf("unexpected receipt: %s", first)
	}
	changed := readJSON[contract.Proposal](t, path)
	changed.Ceiling = 26
	writeJSON(t, path, changed)
	native(t, db, false, "enqueue", path)
	deny := filepath.Join(work, "deny.cedar")
	if err := os.WriteFile(deny, nil, 0600); err != nil {
		t.Fatal(err)
	}
	native(t, db, true, "publish", deny, "0", "2")
	native(t, db, false, "execute", "demo-family", "infer")
	if !bytes.Equal(first, native(t, db, true, "lookup", "demo-family", "infer")) {
		t.Fatal("revocation lost original receipt")
	}
}
func TestStreamProposalToNativeWire(t *testing.T) {
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	work := t.TempDir()
	db := filepath.Join(work, "ledger.db")
	sum := sha256.Sum256([]byte("original-input"))
	input := hex.EncodeToString(sum[:])
	manifest := streaming.Contract{Family: "f", Node: "emit", Profile: "p", Target: "t", InputDigest: input,
		Destination: "tcp://" + listener.Addr().String(), Messages: []streaming.MessageRule{
			{ID: "m0", MaxBytes: 64, CostBound: 4}, {ID: "m1", MaxBytes: 64, CostBound: 4}}}
	digest, err := manifest.Digest()
	if err != nil {
		t.Fatal(err)
	}
	task := contract.Task{Family: "f", Principal: "alice", Profile: "p", Nodes: []string{"emit"}, Targets: []string{"t"},
		Endpoints: map[string]string{"t": "https://provider.invalid/"}, Models: []string{"model-a"}, Budget: 12,
		BodyDigests: map[string]string{"emit": input}, NodeCostBounds: map[string]uint64{"emit": 12}, StreamContracts: map[string]string{"emit": digest}}
	taskPath := filepath.Join(work, "task.json")
	manifestPath := filepath.Join(work, "contract.json")
	writeJSON(t, taskPath, task)
	writeJSON(t, manifestPath, manifest)
	wire := []byte("data: governed\n\n")
	payload := filepath.Join(work, "payload")
	if err := os.WriteFile(payload, wire, 0600); err != nil {
		t.Fatal(err)
	}
	policy := filepath.Join(root(t), "dev/policies/streaming/stream.cedar")
	schema := filepath.Join(root(t), "dev/policies/streaming/schema.json")
	native(t, db, true, "publish-typed", policy, schema, "new", "1")
	native(t, db, true, "register", taskPath)
	native(t, db, true, "stream-register", manifestPath)
	paths := []string{filepath.Join(work, "m0.json"), filepath.Join(work, "m1.json")}
	for i, path := range paths {
		proposal := command(t, true, goCLI, "stream", taskPath, manifestPath, fmt.Sprintf("m%d", i), payload, "4", "0", "1")
		if err := os.WriteFile(path, proposal, 0600); err != nil {
			t.Fatal(err)
		}
		first := native(t, db, true, "stream-enqueue", path)
		if !bytes.Equal(first, native(t, db, true, "stream-enqueue", path)) {
			t.Fatal("message replay changed receipt")
		}
	}
	received := make(chan []byte, 1)
	failure := make(chan error, 1)
	go func() {
		_ = listener.SetDeadline(time.Now().Add(5 * time.Second))
		conn, err := listener.AcceptTCP()
		if err != nil {
			failure <- err
			return
		}
		defer conn.Close()
		_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		data, err := io.ReadAll(conn)
		if err != nil {
			failure <- err
			return
		}
		received <- data
	}()
	native(t, db, true, "stream-send", manifestPath, "m0", "0", "1", "4")
	select {
	case got := <-received:
		if !bytes.Equal(got, wire) {
			t.Fatalf("wire mismatch: %q", got)
		}
	case err := <-failure:
		t.Fatal(err)
	case <-time.After(5 * time.Second):
		t.Fatal("receiver deadline")
	}
	var receipt struct {
		State  string
		Cursor uint64
	}
	if err := json.Unmarshal(native(t, db, true, "stream-lookup", "f", "emit", "m0"), &receipt); err != nil {
		t.Fatal(err)
	}
	if receipt.State != "complete" || receipt.Cursor != uint64(len(wire)) {
		t.Fatal("incomplete durable receipt")
	}
	deny := filepath.Join(work, "deny.cedar")
	if err := os.WriteFile(deny, []byte("forbid(principal,action,resource);"), 0600); err != nil {
		t.Fatal(err)
	}
	native(t, db, true, "publish-typed", deny, schema, "0", "2")
	native(t, db, false, "stream-send", manifestPath, "m1", "1", "2", "4")
	_ = listener.SetDeadline(time.Now().Add(250 * time.Millisecond))
	if conn, err := listener.Accept(); err == nil {
		conn.Close()
		t.Fatal("revoked connection opened")
	} else if e, ok := err.(net.Error); !ok || !e.Timeout() {
		t.Fatal(err)
	}
	changed := readJSON[streaming.Message](t, paths[0])
	changed.Payload = "changed under a fresh nonce"
	forged := filepath.Join(work, "forged.json")
	writeJSON(t, forged, changed)
	native(t, db, false, "stream-enqueue", forged)
	var held uint64
	if err := json.Unmarshal(native(t, db, true, "held", "f"), &held); err != nil {
		t.Fatal(err)
	}
	if held != 8 {
		t.Fatalf("original shared hold changed: %d", held)
	}
}
