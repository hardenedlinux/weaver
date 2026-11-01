package devrunner

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestModelViewsUseActualSDK(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(cwd)
	if err != nil {
		t.Fatal(err)
	}
	capture, err := CaptureModelViews(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	if capture.ModelHash == "" || len(capture.Views) != 8 {
		t.Fatalf("missing native model views: %+v", capture)
	}
	for name, view := range capture.Views {
		if len(view.Nodes) == 0 {
			t.Fatalf("SDK returned an empty view: %s", name)
		}
		t.Logf("%s: %s, %d nodes, %d edges", name, view.Kind, len(view.Nodes), len(view.Edges))
	}
	for _, name := range []string{"architecture", "zeroTrust", "execution", "assurance", "gateway", "contractRefinement", "rangeRecovery", "storage"} {
		if _, ok := capture.Views["WeaverViews::"+name]; !ok {
			t.Fatalf("missing declared view: %s", name)
		}
	}
	security := capture.Views["WeaverViews::contractRefinement"]
	names := map[string]string{}
	for _, node := range security.Nodes {
		names[node.ID] = strings.TrimPrefix(node.Name, "WeaverZeroTrust::refinement::")
	}
	contracts := map[string]bool{"core->usage": false, "usage->application": false, "parents->application": false, "application->enforcement": false}
	for _, edge := range security.Edges {
		key := names[edge.From] + "->" + names[edge.To]
		if _, known := contracts[key]; !known || contracts[key] {
			t.Fatalf("unexpected or duplicate contract refinement: %s", key)
		}
		contracts[key] = true
	}
	for key, retained := range contracts {
		if !retained {
			t.Fatalf("SPEC-to-execution refinement omitted: %s", key)
		}
	}
}

func TestModelViewFailureCannotPublishOverPriorCapture(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".cache/d2"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "Project.sysml"), []byte("package Broken {"), 0644); err != nil {
		t.Fatal(err)
	}
	prior := []byte(`{"modelHash":"historical"}`)
	path := filepath.Join(root, ".cache/d2/model-views.json")
	if err := os.WriteFile(path, prior, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := publishModelViews(t.Context(), root); err == nil {
		t.Fatal("invalid model produced a fresh capture")
	}
	after, err := os.ReadFile(path)
	if err != nil || string(after) != string(prior) {
		t.Fatalf("failed capture replaced historical data: %q, %v", after, err)
	}
}

func TestModelCaptureRequiresLeanEnvironmentAndKeepsSDKTransport(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(cwd)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := publishModelViews(t.Context(), root); err == nil || !strings.Contains(err.Error(), "lacks current Lean environment") {
		t.Fatalf("security projection admitted missing Lean data: %v", err)
	}
	capture, err := CaptureModelViews(t.Context(), root)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(capture)
	if err != nil {
		t.Fatal(err)
	}
	var saved ModelViewCapture
	if err := json.Unmarshal(raw, &saved); err != nil {
		t.Fatal(err)
	}
	if saved.ModelHash == "" || len(saved.Views["WeaverViews::zeroTrust"].Edges) == 0 {
		t.Fatal("transport lost the actual SDK contract refinement model")
	}
	var transport struct {
		Views map[string]map[string]json.RawMessage `json:"views"`
	}
	if err := json.Unmarshal(raw, &transport); err != nil {
		t.Fatal(err)
	}
	for _, view := range transport.Views {
		if _, ok := view["nodes"]; !ok {
			t.Fatal("SDK JSON transport field casing is not interoperable")
		}
	}
}

func TestModelCaptureRejectsSourceAlias(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "source.sysml")
	if err := os.WriteFile(path, []byte("package Alias {}"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(path, filepath.Join(root, "Project.sysml")); err != nil {
		t.Fatal(err)
	}
	if _, err := CaptureModelViews(t.Context(), root); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("source alias was accepted: %v", err)
	}
}

// This metamorphic property exercises the actual SDK: a source rename must
// change the captured model identity and rendered name, preserving the old
// capture as historical data rather than silently rebinding it.
func FuzzModelViewCaptureTracksSource(f *testing.F) {
	f.Add(uint16(0))
	f.Add(uint16(65535))
	f.Fuzz(func(t *testing.T, suffix uint16) {
		root := t.TempDir()
		if err := os.MkdirAll(filepath.Join(root, "dev/sysml"), 0755); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(root, "Project.sysml")
		source := `package CaptureTest {
 private import Views::*;
 private import StandardViewDefinitions::*;
 part def Assembly { part sender; part receiver; connect sender to receiver; }
 view topology { expose Assembly; render asInterconnectionDiagram; }
}`
		if err := os.WriteFile(path, []byte(source), 0644); err != nil {
			t.Fatal(err)
		}
		before, err := CaptureModelViews(t.Context(), root)
		if err != nil {
			t.Fatal(err)
		}
		name := fmt.Sprintf("producer_%04x", suffix)
		if err := os.WriteFile(path, []byte(strings.ReplaceAll(source, "sender", name)), 0644); err != nil {
			t.Fatal(err)
		}
		after, err := CaptureModelViews(t.Context(), root)
		if err != nil {
			t.Fatal(err)
		}
		if before.ModelHash == after.ModelHash || before.Sources["Project.sysml"] == after.Sources["Project.sysml"] {
			t.Fatal("source change did not change the native model capture")
		}
		contains := func(capture *ModelViewCapture, name string) bool {
			for _, node := range capture.Views["CaptureTest::topology"].Nodes {
				if node.Name == name {
					return true
				}
			}
			return false
		}
		if !contains(before, "sender") || contains(before, name) || !contains(after, name) || contains(after, "sender") {
			t.Fatal("rendered identity did not follow the captured source")
		}
	})
}

func TestReadmeProductArchitectureDoesNotSubstituteEngineeringWorkflow(t *testing.T) {
	root, err := FindRoot(".")
	if err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join(root, "README.org"))
	if err != nil {
		t.Fatal(err)
	}
	architecture, _, found := strings.Cut(string(body), "* Workspace")
	if !found {
		t.Fatal("missing README product boundary")
	}
	for _, tool := range []string{"Quint explores", "SysML specifies", "PBT generates", "00c-readme-assurance.svg"} {
		if strings.Contains(architecture, tool) {
			t.Fatalf("engineering workflow substituted for product architecture: %s", tool)
		}
	}
	for _, figure := range []string{"00a-readme-overview.svg", "00d-zero-trust-overview.svg", "00c-gateway-runtime.svg"} {
		if !strings.Contains(architecture, "[[file:docs/architecture/diagrams/"+figure+"]]") {
			t.Fatalf("missing product view: %s", figure)
		}
	}
	capture, err := CaptureModelViews(t.Context(), root)
	if err != nil {
		t.Fatal(err)
	}
	for name, types := range map[string][]string{
		"zeroTrust": {"SchemeSemanticPublisher", "RustPolicy", "RustLedger", "RustFinalBroker", "HttpsExecutor"},
		"gateway":   {"ProtocolIngress", "RoutineProgram", "ModelCatalog", "Routing", "RustExecution", "ModelProviders", "StreamLifecycle"},
	} {
		view := capture.Views["WeaverViews::"+name]
		if view == nil {
			t.Fatalf("missing native product view: %s", name)
		}
		for _, node := range view.Nodes {
			owner := "dev/sysml/GatewayArchitecture.sysml"
			if name == "zeroTrust" {
				owner = "dev/sysml/WeaverExecution.sysml"
			}
			if node.Origin == nil || node.Origin.File != owner {
				t.Fatalf("product node has developer-workflow origin: %+v", node)
			}
		}
		for _, expected := range types {
			present := false
			for _, node := range view.Nodes {
				if node.Type == expected || strings.HasSuffix(node.Type, "::"+expected) {
					present = true
				}
			}
			if !present {
				t.Fatalf("%s omits runtime component %s", name, expected)
			}
		}
	}
	for _, name := range []string{"assurance", "contractRefinement"} {
		description := capture.Descriptions["WeaverViews::"+name]
		if description == nil || !strings.HasPrefix(description.File, "docs/50-59-research-program/") {
			t.Fatalf("engineering reference is not separated: %+v", description)
		}
	}
}
