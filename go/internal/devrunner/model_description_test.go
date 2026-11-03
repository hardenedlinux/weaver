// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/Open-MBEE/OpenSysML/client/opensysml"
)

func FuzzModelDescriptionUsesInheritedSDKAttributes(f *testing.F) {
	f.Add("Original task stays bound")
	f.Add("Only the final owner may send")
	f.Add("Retain unknown exposure")
	f.Fuzz(func(t *testing.T, label string) {
		if strings.TrimSpace(label) == "" || len(label) > 128 {
			t.Skip()
		}
		for _, r := range label {
			if r < 32 || r > 126 {
				t.Skip()
			}
		}
		client, err := opensysml.New(opensysml.WithCacheSize(1))
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		source := fmt.Sprintf(`package Probe {
private import ScalarValues::*; private import Views::*; private import StandardViewDefinitions::*;
part def Component { attribute displayName : String = %s; attribute responsibility : String = "Semantic constraint"; attribute glyph : String = "model"; }
part node : Component;
requirement def Contract;
view read { requirement proof : Contract; attribute mappedFile : String = "docs/view.d2"; attribute displayTitle : String = %s; attribute displaySubtitle : String = "Source-owned interpretation"; attribute displayEyebrow : String = "MODEL"; attribute readerQuestion : String = "Who owns this requirement?"; expose node; render asInterconnectionDiagram; }
}`, strconv.Quote(label), strconv.Quote(label))
		ctx := context.Background()
		model, err := client.ParseSource(ctx, source, opensysml.WithStrictConformance())
		if err != nil || !model.OK() {
			t.Fatalf("SDK input rejected: %v %+v", err, model)
		}
		view, err := client.RenderView(ctx, model, "Probe::read")
		if err != nil {
			t.Fatal(err)
		}
		description, err := describeModelView(ctx, client, model, "Probe::read", view)
		if err != nil || description == nil || description.Heading != label || len(description.Captions) != 1 || description.Captions[0].Label != label+"\nSemantic constraint" {
			t.Fatalf("source meaning replaced: %+v %v", description, err)
		}
		if len(description.Requirements) != 1 || description.Requirements[0].Name != "Contract" || description.Requirements[0].ID != "Probe::Contract" {
			t.Fatal("typed requirement reference lost")
		}
	})
}
