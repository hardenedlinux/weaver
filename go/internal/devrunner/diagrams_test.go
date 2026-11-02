package devrunner

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSequenceEvidenceRequiresDeclaredSyntheticLifelines(t *testing.T) {
	image := diagramImage{Layout: "sequence-view", Source: "docs/view.d2", SourceSHA256: "bound-source", Nodes: 1, Edges: 1}
	valid := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><metadata>{"layout":"sequence-view","view":{"source":"docs/view.d2"},"sourceSHA256":{"docs/view.d2":"bound-source"},"presentation":{"actors":["a"],"lifelines":["line"]},"model":{"subjects":[{"id":"a"}],"relations":[{"id":"line","src":"a","dst":"time-marker"}]}}</metadata><g data-scene-node="a"/><g data-scene-edge="line" data-source-id="a" data-target-id="time-marker"/></svg>`
	if err := diagramEvidence([]byte(valid), image); err != nil {
		t.Fatal(err)
	}
	for _, broken := range []string{
		strings.Replace(valid, `"lifelines":["line"]`, `"lifelines":["other"]`, 1),
		strings.Replace(valid, `"actors":["a"]`, `"actors":["unknown"]`, 1),
		strings.Replace(valid, `"dst":"time-marker"`, `"dst":"time-marker","label":"hidden message"`, 1),
		strings.Replace(valid, `"dst":"time-marker"`, `"dst":"time-marker","dstArrow":"triangle"`, 1),
		strings.Replace(valid, `"layout":"sequence-view"`, `"layout":"model-view"`, 1),
	} {
		if err := diagramEvidence([]byte(broken), image); err == nil {
			t.Fatal("undeclared or decorated synthetic relationship accepted")
		}
	}
}

func TestSequenceExportsRetainActualSourceCoverage(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(cwd)
	if err != nil {
		t.Fatal(err)
	}
	for _, view := range []struct {
		name         string
		nodes, edges int
	}{
		{"02-admission-sequence", 6, 22}, {"04-consume-timeout", 5, 15},
		{"09-claim-wins-race", 6, 20}, {"10-commit-dispatch-sequence", 6, 21},
	} {
		t.Run(view.name, func(t *testing.T) {
			source := "docs/architecture/diagrams/" + view.name + ".d2"
			body, err := os.ReadFile(filepath.Join(root, source))
			if err != nil {
				t.Fatal(err)
			}
			svg, err := os.ReadFile(filepath.Join(root, "docs/architecture/diagrams/"+view.name+".svg"))
			if err != nil {
				t.Fatal(err)
			}
			image := diagramImage{Layout: "sequence-view", Source: source, SourceSHA256: fmt.Sprintf("%x", sha256.Sum256(body)), Nodes: view.nodes, Edges: view.edges}
			if err := diagramEvidence(svg, image); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestDiagramProfilesAreExplicitAndLocal(t *testing.T) {
	root := t.TempDir()
	themes := filepath.Join(root, "dev/d2/themes")
	if err := os.MkdirAll(themes, 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"system", "sequence", "base"} {
		if err := os.WriteFile(filepath.Join(themes, name+".d2"), []byte("# theme"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	docs := filepath.Join(root, "docs")
	if err := os.MkdirAll(docs, 0755); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(docs, "view.d2")
	cases := []struct{ name, body, want string }{
		{"system", "...@../dev/d2/themes/system\na -> b", "system"},
		{"sequence", "...@../dev/d2/themes/sequence\nshape: sequence_diagram\na -> b", "sequence"},
		{"missing", "a -> b", ""},
		{"unknown", "...@../dev/d2/themes/unknown\na -> b", ""},
		{"base-is-not-a-view", "...@../dev/d2/themes/base\na -> b", ""},
		{"duplicate", "...@../dev/d2/themes/system\n...@../dev/d2/themes/sequence\na -> b", ""},
		{"override", "...@../dev/d2/themes/system\nvars: { d2-config: { theme-id: 3 } }\na -> b", ""},
		{"outside-owner", "...@../../themes/system\na -> b", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if err := os.WriteFile(source, []byte(c.body), 0644); err != nil {
				t.Fatal(err)
			}
			got, err := diagramProfile(root, source)
			if c.want == "" {
				if err == nil {
					t.Fatalf("accepted invalid profile: %s", c.body)
				}
			} else if err != nil || got != c.want {
				t.Fatalf("got %q, %v", got, err)
			}
		})
	}
}

func TestDiagramSVGRejectsInvalidToolOutput(t *testing.T) {
	for _, text := range []string{"", "not SVG", `<html/>`, `<svg xmlns="http://www.w3.org/2000/svg"/>`, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">`} {
		if err := checkDiagramSVG([]byte(text)); err == nil {
			t.Fatalf("invalid SVG accepted: %q", text)
		}
	}
	if err := checkDiagramSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"></svg>`)); err != nil {
		t.Fatal(err)
	}
}

func TestDiagramEvidenceRejectsLostNodesAndRelationships(t *testing.T) {
	image := diagramImage{Layout: "model-view", Source: "docs/view.d2", SourceSHA256: "bound-source", Nodes: 2, Edges: 1}
	valid := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><metadata>{"layout":"model-view","view":{"source":"docs/view.d2"},"sourceSHA256":{"docs/view.d2":"bound-source"},"model":{"subjects":[{"id":"a"},{"id":"b"}],"relations":[{"id":"edge","src":"a","dst":"b"}]}}</metadata><g data-scene-node="a"/><g data-scene-node="b"/><g data-scene-edge="edge" data-source-id="a" data-target-id="b"/></svg>`
	if err := diagramEvidence([]byte(valid), image); err != nil {
		t.Fatal(err)
	}
	for _, broken := range []string{
		strings.Replace(valid, `<g data-scene-node="b"/>`, "", 1),
		strings.Replace(valid, `<g data-scene-edge="edge" data-source-id="a" data-target-id="b"/>`, "", 1),
		strings.Replace(valid, `data-source-id="a" data-target-id="b"`, `data-source-id="b" data-target-id="a"`, 1),
		strings.Replace(valid, `"dst":"b"`, `"dst":"missing"`, 1),
		strings.Replace(valid, `"docs/view.d2":"bound-source"`, `"docs/view.d2":"old-source"`, 1),
		strings.Replace(valid, `"layout":"model-view"`, `"layout":"d2-reference"`, 1),
		strings.Replace(valid, `<g data-scene-node="b"/>`, `<g data-scene-node="a"/>`, 1),
	} {
		if err := diagramEvidence([]byte(broken), image); err == nil {
			t.Fatal("accepted incomplete or rebound SVG evidence")
		}
	}
}

func TestArchitectureDiagramsUseDifferentViewProfiles(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(cwd)
	if err != nil {
		t.Fatal(err)
	}
	sources, err := diagramSources(root)
	if err != nil {
		t.Fatal(err)
	}
	profiles := map[string]int{}
	for _, source := range sources {
		profile, err := diagramProfile(root, source)
		if err != nil {
			t.Fatal(err)
		}
		profiles[profile]++
	}
	for _, profile := range []string{"system", "routing", "flow", "sequence", "state", "data", "assurance"} {
		if profiles[profile] == 0 {
			t.Fatalf("view grammar absent: %s", profile)
		}
	}
	if len(sources) == 0 || strings.Contains(filepath.Base(sources[0]), "base") {
		t.Fatal("no real architecture views")
	}
}

func TestSourceInputsIncludeDiagramThemesAndLocalBrandAssets(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(cwd)
	if err != nil {
		t.Fatal(err)
	}
	inputs, err := SourceInputs(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"dev/d2/themes/data.d2", "dev/d2/themes/sequence.d2", "docs/architecture/diagrams/assets/go.svg", "docs/architecture/diagrams/assets/rust.svg"} {
		if inputs[path] == "" {
			t.Fatalf("design source missing from provenance: %s", path)
		}
	}
}

func TestDiagramEvidenceRejectsDuplicateMetadataInventory(t *testing.T) {
	image := diagramImage{Source: "docs/view.d2", SourceSHA256: "bound", Nodes: 2, Edges: 0}
	svg := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><metadata>{"source":"docs/view.d2","sourceDigest":"bound","nodes":[{"id":"a"},{"id":"a"}],"edges":[]}</metadata><g data-scene-node="a"/><g data-scene-node="b"/></svg>`
	if err := diagramEvidence([]byte(svg), image); err == nil {
		t.Fatal("duplicate metadata concealed an unmatched rendered node")
	}
}
