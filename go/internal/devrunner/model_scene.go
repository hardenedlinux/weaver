// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/Open-MBEE/OpenSysML/client/opensysml"
)

// ModelScene transports authored reader intent and public Library preferences.
// It does not infer architecture from filenames or replace model relationships.
type ModelScene struct {
	Audience            string            `json:"audience"`
	Medium              string            `json:"medium"`
	Message             string            `json:"message"`
	Focus               []string          `json:"focus"`
	Themes              []string          `json:"themes"`
	Options             map[string]string `json:"options"`
	Width               int               `json:"width"`
	CaptionContext      string            `json:"captionContext,omitempty"`
	Bands               [][]string        `json:"bands,omitempty"`
	Notation            string            `json:"notation,omitempty"`
	BandTitles          []string          `json:"bandTitles,omitempty"`
	BandIcons           []string          `json:"bandIcons,omitempty"`
	ExampleIllustration string            `json:"exampleIllustration,omitempty"`
}

// The public Library Design schema uses captured IDs, never inferred geometry.
type mappedDesign struct {
	Audience          string   `json:"audience"`
	Medium            string   `json:"medium"`
	Message           string   `json:"message"`
	QuestionRefs      []string `json:"questionRefs"`
	RequiredSubjects  []string `json:"requiredSubjects"`
	RequiredRelations []string `json:"requiredRelations"`
	FocalSubjects     []string `json:"focalSubjects"`
}

func bindSceneDesign(description *ModelDescription, view *opensysml.RenderedView) (*mappedDesign, error) {
	scene := description.Scene
	design := &mappedDesign{Audience: scene.Audience, Medium: scene.Medium, Message: scene.Message, QuestionRefs: []string{"q1"}, RequiredSubjects: []string{}, RequiredRelations: []string{}, FocalSubjects: []string{}}
	for _, node := range view.Nodes {
		design.RequiredSubjects = append(design.RequiredSubjects, node.ID)
	}
	// The SDK exposes ordered endpoints, not relation IDs. The Library assigns
	// those IDs during interpretation; do not duplicate that algorithm here.
	// Full captured-edge correspondence remains independently checked on export.
	for _, focus := range scene.Focus {
		matches := []string{}
		for _, caption := range description.Captions {
			if strings.HasSuffix("::"+caption.Name, "::"+focus) {
				matches = append(matches, caption.ID)
			}
		}
		if len(matches) != 1 {
			return nil, fmt.Errorf("design focal object %s is ambiguous or missing", focus)
		}
		design.FocalSubjects = append(design.FocalSubjects, matches[0])
	}
	return design, nil
}

func describeScene(symbol *opensysml.Symbol, attributes map[string]string) (*ModelScene, error) {
	if attributes["designAudience"] == "" {
		return nil, nil
	}
	for _, key := range []string{"designAudience", "designMedium", "designMessage", "designFocus", "visualThemes", "visualOptions"} {
		if strings.TrimSpace(attributes[key]) == "" {
			return nil, fmt.Errorf("missing scene declaration %s", key)
		}
	}
	scene := &ModelScene{Audience: attributes["designAudience"], Medium: attributes["designMedium"], Message: attributes["designMessage"]}
	scene.CaptionContext = attributes["captionContext"]
	scene.Notation = attributes["visualNotation"]
	scene.ExampleIllustration = attributes["exampleIllustration"]
	for key, target := range map[string]*[]string{"visualBandTitles": &scene.BandTitles, "visualBandIcons": &scene.BandIcons} {
		if encoded := attributes[key]; encoded != "" {
			if err := json.Unmarshal([]byte(encoded), target); err != nil {
				return nil, fmt.Errorf("invalid %s: %w", key, err)
			}
		}
	}
	if encoded := attributes["visualBands"]; encoded != "" {
		if err := json.Unmarshal([]byte(encoded), &scene.Bands); err != nil {
			return nil, fmt.Errorf("invalid declared semantic bands: %w", err)
		}
	}
	if (len(scene.BandTitles) > 0 && len(scene.BandTitles) != len(scene.Bands)) || (len(scene.BandIcons) > 0 && len(scene.BandIcons) != len(scene.Bands)) {
		return nil, fmt.Errorf("reading chapter declarations differ")
	}
	var err error
	if scene.Focus, err = sceneNames(attributes["designFocus"]); err != nil {
		return nil, err
	}
	if scene.Themes, err = sceneNames(attributes["visualThemes"]); err != nil {
		return nil, err
	}
	if err = json.Unmarshal([]byte(attributes["visualOptions"]), &scene.Options); err != nil {
		return nil, fmt.Errorf("invalid declared ELK preferences: %w", err)
	}
	if len(scene.Options) == 0 {
		return nil, fmt.Errorf("empty ELK preferences")
	}
	for key, value := range scene.Options {
		if !strings.HasPrefix(key, "elk.") || strings.TrimSpace(value) == "" {
			return nil, fmt.Errorf("invalid ELK preference %s", key)
		}
	}
	for _, attribute := range symbol.Attributes {
		if attribute.Name == "visualWidth" {
			value, ok := attribute.Value.(opensysml.Int)
			if !ok || value < 600 || value > 1600 {
				return nil, fmt.Errorf("invalid visualWidth")
			}
			scene.Width = int(value)
		}
	}
	if scene.Width == 0 {
		return nil, fmt.Errorf("missing visualWidth")
	}
	return scene, nil
}

// Explicit semantic bands are authored with the view, never node-index defaults.
// Compound models retain Library hierarchy; a band declaration cannot flatten it.
func bindSceneGraph(description *ModelDescription, view *opensysml.RenderedView) (*mappedGraph, error) {
	if len(description.Scene.Bands) == 0 {
		return nil, nil
	}
	partitions := map[string]string{}
	for index, band := range description.Scene.Bands {
		if len(band) == 0 {
			return nil, fmt.Errorf("empty semantic band")
		}
		for _, name := range band {
			matches := []string{}
			for _, node := range view.Nodes {
				if strings.HasSuffix("::"+node.Name, "::"+name) {
					matches = append(matches, node.ID)
				}
			}
			if len(matches) != 1 {
				return nil, fmt.Errorf("ambiguous or missing semantic band subject %s", name)
			}
			if _, exists := partitions[matches[0]]; exists {
				return nil, fmt.Errorf("repeated semantic band subject %s", name)
			}
			partitions[matches[0]] = fmt.Sprint(index)
		}
	}
	if len(partitions) != len(view.Nodes) {
		return nil, fmt.Errorf("semantic bands omit captured subjects")
	}
	options := map[string]string{}
	for key, value := range description.Scene.Options {
		options[key] = value
	}
	options["elk.partitioning.activate"] = "true"
	graph := &mappedGraph{ID: "declared-reading-order", LayoutOptions: options}
	for _, node := range view.Nodes {
		if node.Parent != "" {
			return nil, fmt.Errorf("semantic bands cannot flatten captured hierarchy")
		}
		graph.Children = append(graph.Children, mappedGraphNode{ID: node.ID, LayoutOptions: map[string]string{"elk.partitioning.partition": partitions[node.ID]}})
	}
	return graph, nil
}

func sceneNames(value string) ([]string, error) {
	result := strings.Split(value, ",")
	seen := map[string]bool{}
	for index, name := range result {
		name = strings.TrimSpace(name)
		if name == "" || seen[name] {
			return nil, fmt.Errorf("empty or repeated scene reference")
		}
		seen[name], result[index] = true, name
	}
	return result, nil
}

// Authored reading groups identify objects, not coordinates or automatic grids.
func bindObjectRows(description *ModelDescription) ([][]string, error) {
	rows := [][]string{}
	seen := map[string]bool{}
	for _, band := range description.Scene.Bands {
		row := []string{}
		for _, name := range band {
			matches := []string{}
			for _, caption := range description.Captions {
				if strings.HasSuffix("::"+caption.Name, "::"+name) {
					matches = append(matches, caption.ID)
				}
			}
			if len(matches) != 1 || seen[matches[0]] {
				return nil, fmt.Errorf("missing, repeated or ambiguous illustrated object %s", name)
			}
			seen[matches[0]] = true
			row = append(row, matches[0])
		}
		if len(row) == 0 {
			return nil, fmt.Errorf("empty illustrated reading group")
		}
		rows = append(rows, row)
	}
	if len(seen) != len(description.Captions) {
		return nil, fmt.Errorf("illustrated reading groups omit captured objects")
	}
	return rows, nil
}
