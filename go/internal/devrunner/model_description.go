// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"context"
	"fmt"
	"strings"

	"github.com/Open-MBEE/OpenSysML/client/opensysml"
)

type ModelCaption struct {
	ID              string   `json:"id"`
	Name            string   `json:"name"`
	Type            string   `json:"type"`
	Label           string   `json:"label"`
	Icon            string   `json:"icon"`
	Role            string   `json:"role,omitempty"`
	LeanDeclaration string   `json:"leanDeclaration,omitempty"`
	LeanFields      []string `json:"leanFields,omitempty"`
}
type ModelRequirement struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}
type ModelDescription struct {
	File            string             `json:"file"`
	Heading         string             `json:"heading"`
	Subtitle        string             `json:"subtitle"`
	Eyebrow         string             `json:"eyebrow"`
	Question        string             `json:"question"`
	Captions        []ModelCaption     `json:"captions"`
	Source          string             `json:"source"`
	Requirements    []ModelRequirement `json:"requirements"`
	LeanEnvironment bool               `json:"leanEnvironment,omitempty"`
	Columns         int                `json:"columns,omitempty"`
}

func stringAttributes(symbol *opensysml.Symbol) map[string]string {
	values := map[string]string{}
	for _, attribute := range symbol.Attributes {
		if value, ok := attribute.Value.(opensysml.String); ok {
			values[attribute.Name] = string(value)
		}
	}
	return values
}

// Labels are read through the SDK, including inherited typed attributes. No
// SysML text parser or D2-authored responsibility/caption table is introduced.
func describeModelView(ctx context.Context, client opensysml.Client, model *opensysml.Model, name string, view *opensysml.RenderedView) (*ModelDescription, error) {
	symbol, err := client.LookupSymbol(ctx, model, name)
	if err != nil {
		return nil, err
	}
	attributes := stringAttributes(symbol)
	if attributes["mappedFile"] == "" {
		return nil, nil
	}
	for _, key := range []string{"displayTitle", "displaySubtitle", "displayEyebrow", "readerQuestion"} {
		if strings.TrimSpace(attributes[key]) == "" {
			return nil, fmt.Errorf("model view %s lacks %s", name, key)
		}
	}
	description := &ModelDescription{File: attributes["mappedFile"], Heading: attributes["displayTitle"], Subtitle: attributes["displaySubtitle"], Eyebrow: attributes["displayEyebrow"], Question: attributes["readerQuestion"]}
	description.Columns = 2
	for _, attribute := range symbol.Attributes {
		if attribute.Name == "layoutColumns" {
			value, ok := attribute.Value.(opensysml.Int)
			if !ok || value < 1 || value > 4 {
				return nil, fmt.Errorf("invalid typed layoutColumns on %s", name)
			}
			description.Columns = int(value)
		}
	}
	description.LeanEnvironment = attributes["leanEnvironment"] == "required"
	obligations, err := client.Query(ctx, model, opensysml.Query{Scope: []string{name}, Where: opensysml.Equals("@type", "RequirementUsage")})
	if err != nil {
		return nil, err
	}
	for _, obligation := range obligations {
		childID := obligation.ID
		child, err := client.LookupSymbol(ctx, model, childID)
		if err != nil {
			return nil, err
		}
		if child.Type == nil || child.Type.ResolvedKind != "requirementDef" {
			return nil, fmt.Errorf("unresolved view obligation: %s", childID)
		}
		target, err := client.LookupSymbol(ctx, model, child.Type.ResolvedID)
		if err != nil {
			return nil, err
		}
		description.Requirements = append(description.Requirements, ModelRequirement{ID: target.ID, Name: target.Name})
	}
	if len(description.Requirements) == 0 {
		return nil, fmt.Errorf("mapped view has no typed requirement obligations: %s", name)
	}
	if len(view.Nodes) == 0 || view.Nodes[0].Origin == nil {
		return nil, fmt.Errorf("mapped view has no source owner: %s", name)
	}
	description.Source = view.Nodes[0].Origin.File
	qualified := map[string]string{}
	for _, node := range view.Nodes {
		id := node.Name
		if !strings.Contains(id, "::") {
			parent, found := qualified[node.Parent]
			if !found {
				return nil, fmt.Errorf("model node has no qualified owner: %s", node.Name)
			}
			id = parent + "::" + id
		}
		qualified[node.ID] = id
		subject, err := client.LookupSymbol(ctx, model, id)
		if err != nil {
			return nil, err
		}
		values := stringAttributes(subject)
		if description.LeanEnvironment {
			if values["securityName"] == "" || values["securityResponsibility"] == "" {
				return nil, fmt.Errorf("security view lacks architecture explanation: %s", id)
			}
			values["displayName"], values["responsibility"] = values["securityName"], values["securityResponsibility"]
		}
		if strings.TrimSpace(values["displayName"]) == "" || strings.TrimSpace(values["glyph"]) == "" {
			return nil, fmt.Errorf("model subject lacks reader interpretation: %s", id)
		}
		label := values["displayName"]
		if detail := values["responsibility"]; detail != "" {
			label += "\n" + detail
		}
		caption := ModelCaption{ID: node.ID, Name: node.Name, Type: node.Type, Label: label, Icon: values["glyph"], Role: values["visualRole"], LeanDeclaration: values["leanDeclaration"]}
		if description.LeanEnvironment {
			for _, field := range strings.Split(values["leanFields"], ",") {
				caption.LeanFields = append(caption.LeanFields, strings.TrimSpace(field))
			}
		}
		description.Captions = append(description.Captions, caption)
	}
	return description, nil
}
