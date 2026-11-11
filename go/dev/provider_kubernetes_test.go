// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build integration && schemeintegration && kubernetesintegration && !windows

package dev

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestProviderKubernetesAvailability(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	bundle := controlBundle(t, f)
	plan := bundle.Plans[0]
	f.env = append(f.env, hardFactFeedSetting(t, f, plan.Family, plan.Node, [][2]string{{"next", plan.Node}}, nil, "", nil))
	sources := compiledControlSources(false)
	sources.configure(t, f, bundle)
	control := newControlProcess(t, f, writeControlBundle(t, f, bundle, "json"))
	control.useProducer(sources.producer)
	control.prepareUsing(t, serverBinary, "prepare")

	// Simulate a crash after an older available intent was durably staged.
	intent := &pb.HardFactIntent{OperationId: "kubernetes-interrupted", Domain: "availability",
		Revision: 1, PreviousSnapshot: strings.Repeat("0", 64), Available: proto.Bool(true)}
	ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
	defer cancel()
	if _, err := f.admin.RPC.StageHardFact(f.admin.Context(ctx), intent); err != nil {
		t.Fatal(err)
	}

	const group = "weaver.hardenedlinux.org/v1alpha1"
	const collection = "/apis/" + group + "/namespaces/weaver-system/provideravailabilities"
	const name = "provider-availability"
	var mu sync.Mutex
	var installed map[string]any
	uid, generation, resourceVersion, available := "original-uid", 1, 1, false
	events := make(chan string, 8)
	statusRevisions := make(chan uint64, 8)
	cluster := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "Bearer cluster-fixture" {
			t.Error("Kubernetes client did not use the cluster credential")
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		mu.Lock()
		version := strconv.Itoa(resourceVersion)
		object := map[string]any{"apiVersion": group, "kind": "ProviderAvailability",
			"metadata": map[string]any{"name": name, "namespace": "weaver-system", "uid": uid,
				"generation": generation, "resourceVersion": version},
			"spec": map[string]bool{"available": available}, "status": installed}
		switch {
		case r.Method == http.MethodPatch && r.URL.Path == collection+"/"+name+"/status":
			var patch struct {
				Metadata map[string]string
				Status   map[string]any
			}
			if json.NewDecoder(r.Body).Decode(&patch) != nil || patch.Metadata["resourceVersion"] != version || uid != "original-uid" {
				mu.Unlock()
				t.Error("stale or malformed status patch")
				w.WriteHeader(http.StatusConflict)
				return
			}
			installed = patch.Status
			resourceVersion++
			object["status"] = installed
			object["metadata"].(map[string]any)["resourceVersion"] = strconv.Itoa(resourceVersion)
			revision := uint64(installed["revision"].(float64))
			mu.Unlock()
			_ = json.NewEncoder(w).Encode(object)
			statusRevisions <- revision
		case r.Method == http.MethodGet && r.URL.Path == collection+"/"+name:
			mu.Unlock()
			_ = json.NewEncoder(w).Encode(object)
		case r.Method == http.MethodGet && r.URL.Path == collection:
			mu.Unlock()
			if r.URL.Query().Get("fieldSelector") != "metadata.name="+name {
				t.Error("watch/list escaped its configured resource name")
			}
			if r.URL.Query().Get("watch") == "true" {
				w.WriteHeader(http.StatusOK)
				flusher := w.(http.Flusher)
				flusher.Flush()
				for {
					select {
					case <-r.Context().Done():
						return
					case event := <-events:
						_, _ = fmt.Fprintln(w, event)
						flusher.Flush()
						if strings.Contains(event, `"code":410`) {
							return
						}
					}
				}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"apiVersion": group, "kind": "ProviderAvailabilityList",
				"metadata": map[string]string{"resourceVersion": version}, "items": []any{object}})
		default:
			mu.Unlock()
			t.Errorf("unexpected Kubernetes request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(cluster.Close)
	config := filepath.Join(t.TempDir(), "kubeconfig")
	if err := os.WriteFile(config, []byte(fmt.Sprintf(`apiVersion: v1
kind: Config
clusters:
- name: fixture
  cluster: {server: %s}
contexts:
- name: fixture
  context: {cluster: fixture, user: fixture}
users:
- name: fixture
  user: {token: cluster-fixture}
current-context: fixture
`, cluster.URL)), 0600); err != nil {
		t.Fatal(err)
	}
	const binding = `
[kubernetes]
namespace = "weaver-system"
name = "provider-availability"
uid = "original-uid"
domain = "availability"
`
	logPath := filepath.Join(control.directory, "kubernetes.log")
	log, err := os.Create(logPath)
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	startAdapter := func() func() {
		t.Helper()
		command := sourceTOMLCommand(t, control, control.prepareCommand(t.Context(), serverBinary, "reconcile-kubernetes"), binding)
		command.Env = append(command.Env, "KUBECONFIG="+config)
		command.Stdout, command.Stderr = log, log
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- command.Wait() }()
		return func() {
			_ = command.Process.Signal(syscall.SIGTERM)
			select {
			case err := <-done:
				if err != nil {
					t.Error("Kubernetes owner did not exit normally", err)
				}
			case <-time.After(15 * time.Second):
				_ = command.Process.Kill()
				<-done
				t.Error("Kubernetes owner exceeded drain deadline")
			}
		}
	}
	stopAdapter := startAdapter()
	defer func() {
		if stopAdapter != nil {
			stopAdapter()
		}
	}()
	waitStatus := func(want uint64) {
		t.Helper()
		select {
		case got := <-statusRevisions:
			if got != want {
				t.Fatalf("status revision %d, expected %d", got, want)
			}
		case <-ctx.Done():
			data, _ := os.ReadFile(logPath)
			t.Fatalf("status revision %d: %v: %s", want, ctx.Err(), data)
		}
	}
	waitStatus(2)
	if _, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 0 {
		t.Fatal("pending available intent reopened a withdrawn provider", err)
	}
	stopAdapter()
	stopAdapter = nil
	mu.Lock()
	available, generation, resourceVersion = true, 2, resourceVersion+1
	version := strconv.Itoa(resourceVersion)
	mu.Unlock()
	stopAdapter = startAdapter()
	waitStatus(3)
	update := fmt.Sprintf(`{"type":"MODIFIED","object":{"apiVersion":"%s","kind":"ProviderAvailability","metadata":{"namespace":"weaver-system","name":"%s","uid":"original-uid","resourceVersion":"%s"},"spec":{"available":true}}}`, group, name, version)
	events <- update
	events <- update
	if _, err := f.client.Execute(ctx, plan, pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); err != nil || f.primary.Load() != 1 {
		t.Fatal("restored Kubernetes fact failed real provider execution", err)
	}
	mu.Lock()
	uid, generation, resourceVersion, installed = "replacement-uid", 1, resourceVersion+1, nil
	mu.Unlock()
	events <- `{"type":"ERROR","object":{"apiVersion":"v1","kind":"Status","status":"Failure","reason":"Expired","code":410}}`
	for {
		cut, err := f.admin.RPC.InspectHardFact(f.admin.Context(ctx), &pb.Empty{})
		if err != nil {
			t.Fatal(err)
		}
		if cut.GetRevision() == 4 && cut.Available != nil && !cut.GetAvailable() && len(cut.Pending) == 0 {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatalf("replacement UID did not withdraw the original after relist: %v", cut)
		case <-time.After(20 * time.Millisecond):
		}
	}
	if _, err := f.client.Execute(ctx, bundle.Plans[1], pb.Encoding_PROTOBUF, 1, func(*pb.Event) error { return nil }); status.Code(err) != codes.FailedPrecondition || f.primary.Load() != 1 {
		t.Fatal("replacement UID acquired authority or duplicate delivery advanced the cut", err)
	}
}
