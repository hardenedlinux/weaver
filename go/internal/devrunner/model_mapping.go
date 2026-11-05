// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

type mappedQuestion struct {
	Ref         string   `json:"ref"`
	Text        string   `json:"text"`
	FocusRefs   []string `json:"focusRefs"`
	SubjectRefs []string `json:"subjectRefs,omitempty"`
}
type mappedBasis struct {
	CaptureRef     string   `json:"captureRef"`
	ModelRefs      []string `json:"modelRefs"`
	ObligationRefs []string `json:"obligationRefs"`
	EvidenceRefs   []string `json:"evidenceRefs"`
}
type mappedPresentation struct {
	Illustrations       map[string]string `json:"illustrations,omitempty"`
	ObjectRows          [][]string        `json:"objectRows,omitempty"`
	BandTitles          []string          `json:"bandTitles,omitempty"`
	BandIcons           []string          `json:"bandIcons,omitempty"`
	ExampleIllustration string            `json:"exampleIllustration,omitempty"`
	Notation            string            `json:"notation,omitempty"`
	Options             map[string]string `json:"options"`
	Icons               map[string]string `json:"icons"`
	Roles               map[string]string `json:"roles"`
	EdgeLabels          bool              `json:"edgeLabels"`
	Graph               *mappedGraph      `json:"graph,omitempty"`
}
type mappedGraphNode struct {
	ID            string            `json:"id"`
	LayoutOptions map[string]string `json:"layoutOptions"`
}
type mappedGraph struct {
	ID            string            `json:"id"`
	Children      []mappedGraphNode `json:"children"`
	LayoutOptions map[string]string `json:"layoutOptions"`
}
type mappedModelSource struct {
	Ref            string            `json:"ref"`
	View           string            `json:"view"`
	ModelHash      string            `json:"modelHash"`
	PortProjection string            `json:"portProjection"`
	Labels         map[string]string `json:"labels"`
}
type mappedFigure struct {
	Design       *mappedDesign      `json:"design,omitempty"`
	Icons        []string           `json:"icons"`
	Title        string             `json:"title"`
	Purpose      string             `json:"purpose"`
	Kind         string             `json:"kind"`
	Language     string             `json:"language"`
	Width        int                `json:"width"`
	Primary      string             `json:"primary"`
	Questions    []mappedQuestion   `json:"questions"`
	References   map[string]string  `json:"references"`
	Copy         map[string]string  `json:"copy"`
	Basis        mappedBasis        `json:"basis"`
	Themes       []string           `json:"themes"`
	Layout       string             `json:"layout"`
	Variants     []json.RawMessage  `json:"variants"`
	Presentation mappedPresentation `json:"presentation"`
	ModelSource  *mappedModelSource `json:"modelSource,omitempty"`
}

var mappedJSON = regexp.MustCompile(`(?s)\|json\s*\n(.*?)\n\|`)

// D2 is a generated projection. Only aesthetic inputs (theme, width and ELK
// options) survive from its prior declaration; all semantic copy comes from SDK
// attributes and source-bound Lean references. The Library still owns drawing.
func mapModelDeclarations(root string, capture *ModelViewCapture) error {
	results, err := currentLeanResults(root)
	if err != nil {
		return err
	}
	return mapModelDeclarationsWithEvidence(root, capture, results)
}

func mapModelDeclarationsWithEvidence(root string, capture *ModelViewCapture, results []Result) error {
	inputs, err := SourceInputs(root)
	if err != nil {
		return err
	}
	contracts, err := currentLeanEnvironment(root, results)
	if err != nil {
		return err
	}
	capture.LeanContracts = contracts
	capture.ProofReferences, err = proofReferences(root, results)
	if err != nil {
		return err
	}
	capture.ProofSources = map[string]string{}
	for _, ref := range capture.ProofReferences {
		if !filepath.IsLocal(ref.Source) || !strings.HasPrefix(ref.Source, "dev/proofs/") || filepath.Ext(ref.Source) != ".lean" {
			return fmt.Errorf("nonlocal proof reference: %s", ref.Source)
		}
		if inputs[ref.Source] == "" {
			return fmt.Errorf("proof reference outside maintained source inventory: %s", ref.Source)
		}
		body, err := os.ReadFile(filepath.Join(root, ref.Source))
		if err != nil {
			return err
		}
		capture.ProofSources[ref.Source] = string(body)
	}
	capture.Mapped = map[string]string{}
	for view, description := range capture.Descriptions {
		if _, duplicate := capture.Mapped[description.File]; duplicate {
			return fmt.Errorf("duplicate mapped output: %s", description.File)
		}
		if !filepath.IsLocal(description.File) || !strings.HasPrefix(description.File, "docs/") || filepath.Ext(description.File) != ".d2" {
			return fmt.Errorf("nonlocal mapped view: %s", description.File)
		}
		profile, err := diagramProfile(root, filepath.Join(root, description.File))
		if err != nil {
			return err
		}
		prior, err := os.ReadFile(filepath.Join(root, description.File))
		if err != nil {
			return err
		}
		match := mappedJSON.FindSubmatch(prior)
		if match == nil {
			return fmt.Errorf("mapped view lacks visual declaration: %s", description.File)
		}
		var style mappedFigure
		if err := json.Unmarshal(match[1], &style); err != nil {
			return err
		}
		if style.Width < 1 || len(style.Themes) == 0 {
			return fmt.Errorf("mapped view lacks visual theme/width: %s", description.File)
		}
		modelRefs := make([]string, 0, len(capture.Sources))
		for source := range capture.Sources {
			modelRefs = append(modelRefs, source)
		}
		slices.Sort(modelRefs)
		if capture.Sources[description.Source] == "" {
			return fmt.Errorf("model owner source is not captured: %s", description.Source)
		}
		refs := map[string]string{"model": description.Source}
		for index, source := range modelRefs {
			refs[fmt.Sprintf("model%d", index)] = source
		}
		selected := map[string]bool{}
		for _, ref := range capture.ProofReferences {
			if slices.ContainsFunc(description.Requirements, func(contract ModelRequirement) bool { return contract.Name == ref.Requirement }) {
				selected[ref.Source] = true
			}
		}
		proofs := make([]string, 0, len(selected))
		for source := range selected {
			proofs = append(proofs, source)
		}
		slices.Sort(proofs)
		obligations := []string{}
		for index, source := range proofs {
			key := fmt.Sprintf("proof%d", index)
			refs[key] = source
			obligations = append(obligations, key)
		}
		presentation := mappedPresentation{Options: style.Presentation.Options}
		labels := map[string]string{}
		presentation.Icons, presentation.Roles = map[string]string{}, map[string]string{}
		presentation.Illustrations = map[string]string{}
		for _, caption := range description.Captions {
			if caption.ID == "" || labels[caption.ID] != "" {
				return fmt.Errorf("missing or duplicate SDK caption ID: %s", view)
			}
			label := caption.Label
			if description.LeanEnvironment {
				contract, exists := contracts[caption.LeanDeclaration]
				if !exists {
					return fmt.Errorf("view %s lacks current Lean environment declaration %s", view, caption.LeanDeclaration)
				}
				// Model-assisted architectural explanation stays in SysML.
				// Imported Lean constrains its references; field lists do not
				// become user-facing architecture or prove implementation.
				if err := validateLeanAllocation(caption, contract); err != nil {
					return err
				}
			}
			labels[caption.ID] = label
			presentation.Icons[caption.ID] = caption.Icon
			if caption.Illustration != "" {
				presentation.Illustrations[caption.ID] = caption.Illustration
			}
			if caption.Role != "" {
				presentation.Roles[caption.ID] = caption.Role
			}
		}
		refs["sdkCapture"] = "dev/sysml/captures/" + strings.ReplaceAll(view, "::", "-") + ".json"
		figure := mappedFigure{Icons: []string{"engineering", "weaver", "components"}, Title: description.Heading, Purpose: "architecture", Kind: profile, Language: "en", Width: style.Width, Primary: "q1", Questions: []mappedQuestion{{Ref: "q1", Text: description.Question, FocusRefs: []string{"model"}}}, References: refs, Copy: map[string]string{}, Basis: mappedBasis{CaptureRef: description.File + "#design-view", ModelRefs: modelRefs, ObligationRefs: obligations, EvidenceRefs: []string{}}, Themes: style.Themes, Layout: "model-view", Variants: []json.RawMessage{}, Presentation: presentation}
		switch profile {
		case "routing", "flow", "state", "sequence":
			figure.Purpose = "workflow"
		}
		figure.ModelSource = &mappedModelSource{Ref: "sdkCapture", View: view, ModelHash: capture.ModelHash, PortProjection: "owner", Labels: labels}
		if description.Scene != nil {
			design, err := bindSceneDesign(description, capture.Views[view])
			if err != nil {
				return err
			}
			figure.Design = design
			figure.Width, figure.Themes = description.Scene.Width, description.Scene.Themes
			figure.Presentation.Options = description.Scene.Options
			figure.Presentation.Notation = description.Scene.Notation
			figure.Presentation.BandTitles = description.Scene.BandTitles
			figure.Presentation.BandIcons = description.Scene.BandIcons
			figure.Presentation.ExampleIllustration = description.Scene.ExampleIllustration
			figure.Presentation.EdgeLabels = true
			figure.Presentation.Graph, err = bindSceneGraph(description, capture.Views[view])
			if err != nil {
				return err
			}
			if description.Scene.Notation == "objects" {
				figure.Presentation.ObjectRows, err = bindObjectRows(description)
				if err != nil {
					return err
				}
			}
			figure.Questions[0].SubjectRefs = design.FocalSubjects
		}
		encoded, err := json.MarshalIndent(figure, "", "  ")
		if err != nil {
			return err
		}
		base, err := filepath.Rel(filepath.Dir(description.File), "dev/d2/themes/"+profile)
		if err != nil {
			return err
		}
		capture.Mapped[description.File] = "# SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors\n#\n# SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0\n\n...@" + filepath.ToSlash(base) + "\n# Generated by Go from SysML and Lean references. Edit source contracts, not D2 semantic copy.\nvars: { d2-config: { data: { figure: |json\n" + string(encoded) + "\n|\n} } }\n"
	}
	return nil
}

func writeMappedDeclarations(root string) error {
	data, err := os.ReadFile(filepath.Join(root, ".cache/d2/model-views.json"))
	if err != nil {
		return err
	}
	var capture ModelViewCapture
	if err := json.Unmarshal(data, &capture); err != nil {
		return err
	}
	for source, body := range capture.Mapped {
		if !filepath.IsLocal(source) || !strings.HasPrefix(source, "docs/") || filepath.Ext(source) != ".d2" {
			return fmt.Errorf("invalid mapped output: %s", source)
		}
		path := filepath.Join(root, source)
		if _, err := diagramProfile(root, path); err != nil {
			return err
		}
		prior, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if string(prior) == body {
			continue
		}
		file, err := os.CreateTemp(filepath.Dir(path), ".mapped-*.d2")
		if err != nil {
			return err
		}
		name := file.Name()
		_, writeErr := file.WriteString(body)
		closeErr := file.Close()
		if writeErr != nil || closeErr != nil {
			os.Remove(name)
			return fmt.Errorf("mapped declaration write: %v / %v", writeErr, closeErr)
		}
		if err := os.Chmod(name, 0644); err != nil {
			os.Remove(name)
			return err
		}
		if err := os.Rename(name, path); err != nil {
			os.Remove(name)
			return err
		}
	}
	return nil
}

// Reuse the existing Go-owned receipt, admitting only current proof inputs and
// exact declaration audits. Absent/stale evidence stays NOT_EXECUTED; no proof
// verdict or acceptance annotation is painted into a core architecture view.
func currentLeanResults(root string) ([]Result, error) {
	data, err := os.ReadFile(latestResultPath(root, "check-policy"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var receipt Receipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		return nil, err
	}
	if receipt.Root != root || receipt.Status != "PASS" {
		return nil, nil
	}
	current, err := SourceInputs(root)
	if err != nil {
		return nil, err
	}
	if !maps.Equal(current, receipt.Inputs) {
		return nil, nil
	}
	return receipt.Stages, nil
}
