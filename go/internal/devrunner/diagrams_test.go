package devrunner

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
	image := diagramImage{Source: "docs/view.d2", SourceSHA256: "bound-source", Nodes: 2, Edges: 1}
	valid := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><metadata>{"source":"docs/view.d2","sourceDigest":"bound-source","nodes":[{"id":"a"},{"id":"b"}],"edges":[{"id":"edge","source":"a","target":"b"}]}</metadata><g data-source-node="a"/><g data-source-node="b"/><g data-source-edge="edge"/></svg>`
	if err := diagramEvidence([]byte(valid), image); err != nil {
		t.Fatal(err)
	}
	for _, broken := range []string{
		strings.Replace(valid, `<g data-source-node="b"/>`, "", 1),
		strings.Replace(valid, `<g data-source-edge="edge"/>`, "", 1),
		strings.Replace(valid, `"target":"b"`, `"target":"missing"`, 1),
		strings.Replace(valid, `"sourceDigest":"bound-source"`, `"sourceDigest":"old-source"`, 1),
		strings.Replace(valid, `<g data-source-node="b"/>`, `<g data-source-node="a"/>`, 1),
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
