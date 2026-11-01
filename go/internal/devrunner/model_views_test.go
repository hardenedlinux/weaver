package devrunner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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
	if capture.ModelHash == "" || len(capture.Views) != 4 {
		t.Fatalf("missing native model views: %+v", capture)
	}
	for name, view := range capture.Views {
		if len(view.Nodes) == 0 {
			t.Fatalf("SDK returned an empty view: %s", name)
		}
		t.Logf("%s: %s, %d nodes, %d edges", name, view.Kind, len(view.Nodes), len(view.Edges))
	}
	for _, name := range []string{"architecture", "zeroTrust", "execution", "assurance"} {
		if _, ok := capture.Views["WeaverViews::"+name]; !ok {
			t.Fatalf("missing declared view: %s", name)
		}
	}
	if len(capture.Views["WeaverViews::zeroTrust"].Edges) == 0 {
		t.Fatal("security view lost the actual Gateway connections")
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

func TestModelCapturePublishesExactSDKTransport(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(cwd)
	if err != nil {
		t.Fatal(err)
	}
	digest, err := publishModelViews(t.Context(), root)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(root, ".cache/d2/model-views.json"))
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(raw)
	if digest != hex.EncodeToString(sum[:]) {
		t.Fatal("published bytes differ from the Go owner receipt")
	}
	var saved ModelViewCapture
	if err := json.Unmarshal(raw, &saved); err != nil {
		t.Fatal(err)
	}
	if saved.ModelHash == "" || len(saved.Views["WeaverViews::zeroTrust"].Edges) == 0 {
		t.Fatal("transport lost the actual SDK security model")
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
