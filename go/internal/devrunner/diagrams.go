package devrunner

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"image/png"
	"io"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

var diagramImport = regexp.MustCompile(`(?m)^\.\.\.@([^\r\n]+)$`)
var diagramThemeOverride = regexp.MustCompile(`\btheme-id\s*:`)

func diagramProfile(root, source string) (string, error) {
	info, err := os.Lstat(source)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("diagram source must be regular: %s", source)
	}
	data, err := os.ReadFile(source)
	if err != nil {
		return "", err
	}
	if diagramThemeOverride.Match(data) {
		return "", fmt.Errorf("diagram must select its theme through dev/d2/themes: %s", source)
	}
	var profile string
	for _, match := range diagramImport.FindAllSubmatch(data, -1) {
		path := strings.TrimSpace(string(match[1]))
		if filepath.Ext(path) == "" {
			path += ".d2"
		}
		path = filepath.Clean(filepath.Join(filepath.Dir(source), path))
		if filepath.Dir(path) != filepath.Join(root, "dev/d2/themes") {
			continue
		}
		if profile != "" || filepath.Base(path) == "base.d2" {
			return "", fmt.Errorf("diagram needs exactly one view profile: %s", source)
		}
		info, err := os.Lstat(path)
		if err != nil {
			return "", err
		}
		if !info.Mode().IsRegular() {
			return "", fmt.Errorf("theme must be regular: %s", path)
		}
		profile = strings.TrimSuffix(filepath.Base(path), ".d2")
	}
	if profile == "" {
		return "", fmt.Errorf("diagram has no view profile: %s", source)
	}
	return profile, nil
}

func diagramSources(root string) ([]string, error) {
	var sources []string
	err := filepath.WalkDir(filepath.Join(root, "docs"), func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() && entry.Name() == "lib" {
			return fs.SkipDir
		}
		if !entry.IsDir() && filepath.Ext(path) == ".d2" {
			if _, err := diagramProfile(root, path); err != nil {
				return err
			}
			sources = append(sources, path)
		}
		return nil
	})
	slices.Sort(sources)
	if err == nil && len(sources) == 0 {
		err = errors.New("no architecture diagram views")
	}
	return sources, err
}

func checkDiagramSVG(data []byte) error {
	var svg struct {
		XMLName xml.Name `xml:"http://www.w3.org/2000/svg svg"`
		ViewBox string   `xml:"viewBox,attr"`
	}
	if err := xml.Unmarshal(data, &svg); err != nil {
		return err
	}
	if svg.ViewBox == "" {
		return errors.New("rendered SVG has no viewBox")
	}
	return nil
}

type diagramImage struct {
	Layout       string `json:"layout"`
	Source       string `json:"source"`
	Theme        string `json:"theme"`
	SourceSHA256 string `json:"sourceSHA256"`
	SVG          string `json:"svgSHA256"`
	PNG          string `json:"pngSHA256"`
	Nodes        int    `json:"nodes"`
	Edges        int    `json:"edges"`
}
type diagramRenderReport struct {
	Selection    []string       `json:"selection,omitempty"`
	ModelCapture string         `json:"modelCaptureSHA256"`
	Status       string         `json:"status"`
	HostCPUs     int            `json:"hostCPUs"`
	Workers      int            `json:"workers"`
	Images       []diagramImage `json:"images"`
	Errors       []string       `json:"errors"`
}

func diagramEvidence(data []byte, image diagramImage) error {
	if err := checkDiagramSVG(data); err != nil {
		return err
	}
	decoder := xml.NewDecoder(bytes.NewReader(data))
	nodes, edges := map[string]bool{}, map[string]bool{}
	connections := map[string][2]string{}
	metadataCount := 0
	var metadata struct {
		Layout       string `json:"layout"`
		Presentation struct {
			Actors    []string `json:"actors"`
			Lifelines []string `json:"lifelines"`
		} `json:"presentation"`
		View struct {
			Source string `json:"source"`
		} `json:"view"`
		SourceSHA256 map[string]string `json:"sourceSHA256"`
		Model        struct {
			Subjects []struct {
				ID string `json:"id"`
			} `json:"subjects"`
			Relations []struct{ ID, Src, Dst, Label, SrcArrow, DstArrow string } `json:"relations"`
		} `json:"model"`
	}
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		element, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		if element.Name.Local == "metadata" {
			if slices.ContainsFunc(element.Attr, func(a xml.Attr) bool { return a.Name.Local == "data-scene-input" }) {
				continue
			}
			metadataCount++
			if metadataCount != 1 {
				return errors.New("duplicate graph metadata")
			}
			var text string
			if err := decoder.DecodeElement(&text, &element); err != nil {
				return err
			}
			if err := json.Unmarshal([]byte(text), &metadata); err != nil {
				return err
			}
		}
		var edgeID, from, to string
		for _, attr := range element.Attr {
			switch attr.Name.Local {
			case "data-scene-edge":
				edgeID = attr.Value
			case "data-source-id":
				from = attr.Value
			case "data-target-id":
				to = attr.Value
			}
			var target map[string]bool
			switch attr.Name.Local {
			case "data-scene-node":
				target = nodes
			case "data-scene-edge":
				target = edges
			default:
				continue
			}
			if attr.Value == "" {
				return errors.New("empty visual source identity")
			}
			if target[attr.Value] {
				return fmt.Errorf("duplicated visual source identity: %s", attr.Value)
			}
			target[attr.Value] = true
		}
		if edgeID != "" {
			if from == "" || to == "" {
				return errors.New("visual relationship has no bound endpoints")
			}
			connections[edgeID] = [2]string{from, to}
		}
	}
	if metadataCount != 1 {
		return errors.New("missing graph metadata")
	}
	if image.Layout != "" && image.Layout != metadata.Layout {
		return errors.New("SVG composition differs from its declared source layout")
	}
	if metadata.View.Source != image.Source || metadata.SourceSHA256[image.Source] != image.SourceSHA256 || len(nodes) != image.Nodes || len(edges) != image.Edges || len(metadata.Model.Subjects) != len(nodes) || len(metadata.Model.Relations) != len(edges) {
		return fmt.Errorf("SVG source binding or graph coverage differs: %s", image.Source)
	}
	seenNodes, seenEdges := map[string]bool{}, map[string]bool{}
	for _, node := range metadata.Model.Subjects {
		if node.ID == "" || seenNodes[node.ID] {
			return errors.New("duplicate or empty declared node identity")
		}
		seenNodes[node.ID] = true
		if !nodes[node.ID] {
			return fmt.Errorf("source node omitted: %s", node.ID)
		}
	}
	// D2 sequence captures contain explicit lifeline relationships whose endpoint
	// is a synthetic time marker, not another participant. Admit only the exact
	// source-declared lifeline set; ordinary edges still require both real nodes.
	lifelines, actors, actorLines := map[string]bool{}, map[string]bool{}, map[string]bool{}
	if metadata.Layout == "sequence-view" {
		for _, actor := range metadata.Presentation.Actors {
			if !nodes[actor] || actors[actor] {
				return errors.New("invalid sequence participant")
			}
			actors[actor] = true
		}
		for _, id := range metadata.Presentation.Lifelines {
			if id == "" || lifelines[id] {
				return errors.New("invalid sequence lifeline identity")
			}
			lifelines[id] = true
		}
		if len(actors) == 0 || len(actors) != len(lifelines) {
			return errors.New("incomplete sequence lifelines")
		}
	}
	for _, edge := range metadata.Model.Relations {
		if edge.ID == "" || seenEdges[edge.ID] {
			return errors.New("duplicate or empty declared relationship identity")
		}
		seenEdges[edge.ID] = true
		if connections[edge.ID] != [2]string{edge.Src, edge.Dst} {
			return errors.New("visual relationship endpoints differ from declaration")
		}
		if lifelines[edge.ID] {
			if !actors[edge.Src] || actorLines[edge.Src] || edge.Dst == "" || nodes[edge.Dst] || edge.Label != "" || (edge.SrcArrow != "" && edge.SrcArrow != "none") || (edge.DstArrow != "" && edge.DstArrow != "none") {
				return errors.New("invalid sequence lifeline endpoints or decoration")
			}
			actorLines[edge.Src] = true
		} else if !nodes[edge.Dst] {
			return fmt.Errorf("source relationship omitted: %s", edge.ID)
		}
		if !edges[edge.ID] || !nodes[edge.Src] {
			return fmt.Errorf("source relationship omitted: %s", edge.ID)
		}
	}
	if len(actorLines) != len(lifelines) {
		return errors.New("unrendered sequence lifeline")
	}
	return nil
}

// CheckDiagrams runs TypeScript type/property checks and offline image rendering.
func CheckDiagrams(ctx context.Context, root string, out io.Writer, selected ...string) error {
	modelDigest, err := publishSelectedArchitecture(ctx, root, selected)
	if err != nil {
		return err
	}
	if err := writeMappedDeclarations(root); err != nil {
		return err
	}
	binary, err := exec.LookPath("bun")
	if err != nil {
		return err
	}
	run := func(args ...string) error {
		command := exec.CommandContext(ctx, binary, args...)
		command.Env = append(os.Environ(), "WEAVER_DIAGRAM_MODEL_SHA256="+modelDigest)
		command.Dir = filepath.Join(root, "dev/d2")
		command.Stdout = out
		command.Stderr = out
		return command.Run()
	}
	if err := run("run", "typecheck"); err != nil {
		return err
	}
	if err := renderDiagrams(ctx, root, modelDigest, out, selected...); err != nil {
		return err
	}
	// Browser assertions inspect the newly generated standalone vectors, not the
	// previous checked-in image generation. Unit/property suites run once here.
	if len(selected) != 0 {
		return run("test", "test/model-capture.test.ts", "test/vector-readability.test.ts")
	}
	return run("test")
}

// RenderDiagrams owns a shell-free TypeScript -> SVG/PNG build, not an HTTP service.
func RenderDiagrams(ctx context.Context, root string, out io.Writer, selected ...string) error {
	modelDigest, err := publishSelectedArchitecture(ctx, root, selected)
	if err != nil {
		return err
	}
	if err := writeMappedDeclarations(root); err != nil {
		return err
	}
	return renderDiagrams(ctx, root, modelDigest, out, selected...)
}

func renderDiagrams(ctx context.Context, root, modelDigest string, out io.Writer, selected ...string) error {
	sources, err := diagramSources(root)
	if err != nil {
		return err
	}
	if len(selected) != 0 {
		chosen := make([]string, 0, len(selected))
		for _, source := range sources {
			relative, err := filepath.Rel(root, source)
			if err != nil {
				return err
			}
			if slices.Contains(selected, filepath.ToSlash(relative)) {
				chosen = append(chosen, source)
			}
		}
		if len(chosen) != len(selected) {
			return errors.New("selected image inventory differs from captured scope")
		}
		sources = chosen
	}
	before, err := SourceInputs(root)
	if err != nil {
		return err
	}
	binary, err := exec.LookPath("bun")
	if err != nil {
		return err
	}
	args := []string{"run", "src/render.ts"}
	for _, source := range selected {
		args = append(args, "--view", source)
	}
	command := exec.CommandContext(ctx, binary, args...)
	command.Env = append(os.Environ(), "WEAVER_DIAGRAM_MODEL_SHA256="+modelDigest)
	command.Dir = filepath.Join(root, "dev/d2")
	command.Stdout = out
	command.Stderr = out
	command.Cancel = func() error { return command.Process.Signal(os.Interrupt) }
	runErr := command.Run()
	var failures []error
	if runErr != nil {
		failures = append(failures, runErr)
	}
	data, err := os.ReadFile(filepath.Join(root, ".cache/d2/typescript-render.json"))
	var report diagramRenderReport
	if err == nil {
		err = json.Unmarshal(data, &report)
	}
	if err != nil {
		failures = append(failures, err)
	}
	if report.Status != "PASS" || len(report.Images) != len(sources) {
		failures = append(failures, errors.New("incomplete TypeScript image render"))
	}
	if !slices.Equal(report.Selection, selected) {
		failures = append(failures, errors.New("renderer selection differs from the requested scope"))
	}
	if report.ModelCapture != modelDigest {
		failures = append(failures, errors.New("renderer receipt does not bind the current SDK capture"))
	}
	expected := map[string]bool{}
	for _, source := range sources {
		relative, _ := filepath.Rel(root, source)
		expected[filepath.ToSlash(relative)] = true
	}
	seen := map[string]bool{}
	for _, image := range report.Images {
		if image.Layout == "" {
			failures = append(failures, errors.New("missing declared image composition"))
		}
		if !expected[image.Source] || seen[image.Source] || before[image.Source] != image.SourceSHA256 {
			failures = append(failures, fmt.Errorf("unexpected image source: %s", image.Source))
			continue
		}
		seen[image.Source] = true
		source := filepath.Join(root, filepath.FromSlash(image.Source))
		profile, err := diagramProfile(root, source)
		if err != nil || profile != image.Theme {
			failures = append(failures, fmt.Errorf("image profile mismatch: %s", image.Source))
			continue
		}
		svg, err := os.ReadFile(strings.TrimSuffix(source, ".d2") + ".svg")
		if err == nil {
			sum := sha256.Sum256(svg)
			if hex.EncodeToString(sum[:]) != image.SVG {
				err = errors.New("SVG hash mismatch")
			}
		}
		if err == nil {
			err = diagramEvidence(svg, image)
		}
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", image.Source, err))
		}
		raster, err := os.ReadFile(filepath.Join(root, ".cache/d2/images", strings.TrimSuffix(filepath.FromSlash(image.Source), ".d2")+".png"))
		if err == nil {
			sum := sha256.Sum256(raster)
			if hex.EncodeToString(sum[:]) != image.PNG {
				err = errors.New("PNG hash mismatch")
			}
		}
		if err == nil {
			_, err = png.DecodeConfig(bytes.NewReader(raster))
		}
		if err != nil {
			failures = append(failures, fmt.Errorf("%s: %w", image.Source, err))
		}
	}
	after, err := SourceInputs(root)
	if err != nil {
		failures = append(failures, err)
	} else if !maps.Equal(before, after) {
		failures = append(failures, errors.New("renderer or architecture sources changed during image build"))
	}
	type receipt struct {
		Status string              `json:"status"`
		Inputs map[string]string   `json:"inputs"`
		Report diagramRenderReport `json:"report"`
		Errors []string            `json:"errors,omitempty"`
	}
	result := receipt{Status: "PASS", Inputs: before, Report: report}
	for _, failure := range failures {
		result.Errors = append(result.Errors, failure.Error())
	}
	if len(failures) > 0 {
		result.Status = "FAIL"
	}
	data, err = json.MarshalIndent(result, "", "  ")
	if err == nil {
		err = os.WriteFile(filepath.Join(root, ".cache/d2/latest-render.json"), data, 0644)
	}
	fmt.Fprintf(out, "%s: %d source-bound SVG/PNG views; .cache/d2/latest-render.json\n", result.Status, len(report.Images))
	return errors.Join(append(failures, err)...)
}
