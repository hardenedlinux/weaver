// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package dev

import (
	"encoding/xml"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// Navigation links may have labels; every referenced SVG also needs a real
// standalone Org image so repository readers can see the architecture in place.
func TestProjectArchitectureOrgSVGEmbeds(t *testing.T) {
	references := regexp.MustCompile(`\[\[file:([^\]]+\.svg)\](?:\[[^\]]*\])?\]`)
	paths := []string{filepath.Join(root(t), "README.org")}
	err := filepath.WalkDir(filepath.Join(root(t), "docs"), func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() && strings.HasSuffix(path, ".org") {
			paths = append(paths, path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		lines := map[string]bool{}
		for _, line := range strings.Split(string(body), "\n") {
			lines[strings.TrimSpace(line)] = true
		}
		for _, match := range references.FindAllStringSubmatch(string(body), -1) {
			if !lines["[[file:"+match[1]+"]]"] {
				t.Errorf("%s: SVG needs a standalone file image: %s", path, match[1])
			}
			if info, err := os.Stat(filepath.Join(filepath.Dir(path), match[1])); err != nil || !info.Mode().IsRegular() {
				t.Errorf("%s: image is not a regular file: %s", path, match[1])
			}
		}
	}
}

func TestProjectArchitectureReadmeFigureScale(t *testing.T) {
	readme, err := os.ReadFile(filepath.Join(root(t), "README.org"))
	if err != nil {
		t.Fatal(err)
	}
	images := regexp.MustCompile(`(?m)^\[\[file:([^\]]+\.svg)\]\]$`).FindAllStringSubmatch(string(readme), -1)
	if len(images) < 3 {
		t.Fatal("README must directly embed the overview, execution and assurance SVGs")
	}
	viewport := regexp.MustCompile(`viewBox="0 0 ([0-9.]+) ([0-9.]+)"`)
	fonts := regexp.MustCompile(`\.scene-(title|detail)\{font-size:([0-9.]+)px`)
	for _, image := range images {
		body, err := os.ReadFile(filepath.Join(root(t), image[1]))
		if err != nil {
			t.Fatal(err)
		}
		box := viewport.FindSubmatch(body)
		if len(box) != 3 {
			t.Fatalf("%s: missing SVG viewport", image[1])
		}
		width, _ := strconv.ParseFloat(string(box[1]), 64)
		if width <= 0 || width > 1000 {
			t.Errorf("%s: README viewport too wide: %.0f", image[1], width)
		}
		if !strings.Contains(string(body), `data-renderer="@deterministic-engineering/render"`) {
			t.Errorf("%s: README requires the shared Library's vector export", image[1])
		}
		decoder := xml.NewDecoder(strings.NewReader(string(body)))
		sceneScale, scenes := 1.0, 0
		for {
			token, err := decoder.Token()
			if err == io.EOF {
				break
			}
			if err != nil {
				t.Fatal(err)
			}
			start, ok := token.(xml.StartElement)
			if !ok || start.Name.Local != "svg" {
				continue
			}
			attributes := map[string]string{}
			for _, attribute := range start.Attr {
				attributes[attribute.Name.Local] = attribute.Value
			}
			if _, ok := attributes["data-scene"]; !ok {
				continue
			}
			scenes++
			box := strings.Fields(attributes["viewBox"])
			if len(box) != 4 {
				t.Fatal("scene has no measurable viewport")
			}
			intrinsic, _ := strconv.ParseFloat(box[2], 64)
			displayed, _ := strconv.ParseFloat(attributes["width"], 64)
			if intrinsic <= 0 || displayed <= 0 {
				t.Fatal("scene has an invalid width")
			}
			sceneScale = min(sceneScale, displayed/intrinsic)
		}
		if scenes == 0 {
			t.Fatal("README SVG has no Library scene")
		}
		labels := fonts.FindAllSubmatch(body, -1)
		if len(labels) == 0 {
			t.Fatalf("%s: no measurable labels", image[1])
		}
		sizes := map[string]float64{}
		for _, label := range labels {
			sizes[string(label[1])], _ = strconv.ParseFloat(string(label[2]), 64)
		}
		for _, size := range sizes {
			if size*sceneScale*min(1, 830/width) < 18 {
				t.Errorf("%s: label below 18px at 830px reading width", image[1])
			}
		}
	}
}
