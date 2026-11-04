// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/Open-MBEE/OpenSysML/client/opensysml"
)

type ReaderDesign struct {
	Audience    string            `json:"audience"`
	Medium      string            `json:"medium"`
	Message     string            `json:"message"`
	Width       int               `json:"width"`
	TextColumns int               `json:"textColumns"`
	Themes      []string          `json:"themes"`
	Options     map[string]string `json:"options"`
}

func captureReaderDesigns(ctx context.Context, client opensysml.Client, model *opensysml.Model) (map[string]ReaderDesign, error) {
	symbols, err := client.Query(ctx, model, opensysml.Query{Scope: []string{"WeaverReaderDesigns"}, Where: opensysml.Equals("@type", "PartUsage")})
	if err != nil {
		return nil, err
	}
	designs := map[string]ReaderDesign{}
	for _, ref := range symbols {
		symbol, err := client.LookupSymbol(ctx, model, ref.ID)
		if err != nil {
			return nil, err
		}
		values := stringAttributes(symbol)
		for _, key := range []string{"audience", "medium", "message", "themes", "options"} {
			if strings.TrimSpace(values[key]) == "" {
				return nil, fmt.Errorf("reader Design %s lacks %s", ref.ID, key)
			}
		}
		design := ReaderDesign{Audience: values["audience"], Medium: values["medium"], Message: values["message"], Themes: strings.Split(values["themes"], ",")}
		if err := json.Unmarshal([]byte(values["options"]), &design.Options); err != nil {
			return nil, err
		}
		if design.Options == nil {
			return nil, fmt.Errorf("missing layout options on %s", ref.ID)
		}
		if values["componentPacking"] != "stack" {
			return nil, fmt.Errorf("invalid component packing on %s", ref.ID)
		}
		design.Options["render.componentPacking"] = values["componentPacking"]
		for _, attribute := range symbol.Attributes {
			if attribute.Name == "width" || attribute.Name == "textColumns" {
				value, ok := attribute.Value.(opensysml.Int)
				if !ok {
					return nil, fmt.Errorf("invalid typed reader measure %s", ref.ID)
				}
				if attribute.Name == "width" {
					design.Width = int(value)
				} else {
					design.TextColumns = int(value)
				}
			}
		}
		if design.Width < 600 || design.Width > 1600 || design.TextColumns < 8 || design.TextColumns > 120 {
			return nil, fmt.Errorf("invalid reader Design measure %s", ref.ID)
		}
		parts := strings.Split(ref.ID, "::")
		kind := parts[len(parts)-1]
		if _, exists := designs[kind]; exists {
			return nil, fmt.Errorf("duplicate reader Design %s", kind)
		}
		designs[kind] = design
	}
	return designs, nil
}
