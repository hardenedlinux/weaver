// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package dev

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"slices"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/HardenedLinux/weaver/go/internal/devrunner"
)

type cargoTarget struct {
	Optimized bool
	Name      string
	Kind      string
	Test      bool
}

func readCargoExecutable(input io.Reader, target cargoTarget) (string, error) {
	decoder := json.NewDecoder(input)
	var executable string
	for {
		var artifact struct {
			Reason     string  `json:"reason"`
			Executable *string `json:"executable"`
			Target     struct {
				Name string   `json:"name"`
				Kind []string `json:"kind"`
			} `json:"target"`
			Profile struct {
				Test            bool   `json:"test"`
				OptLevel        string `json:"opt_level"`
				DebugAssertions *bool  `json:"debug_assertions"`
			} `json:"profile"`
		}
		if err := decoder.Decode(&artifact); err == io.EOF {
			break
		} else if err != nil {
			return "", fmt.Errorf("Cargo artifact stream: %w", err)
		}
		if artifact.Reason != "compiler-artifact" || artifact.Target.Name != target.Name ||
			!slices.Contains(artifact.Target.Kind, target.Kind) || artifact.Profile.Test != target.Test || artifact.Executable == nil {
			continue
		}
		if target.Optimized {
			valid := artifact.Profile.OptLevel == "1" || artifact.Profile.OptLevel == "2" || artifact.Profile.OptLevel == "3" || artifact.Profile.OptLevel == "s" || artifact.Profile.OptLevel == "z"
			if !valid || artifact.Profile.DebugAssertions == nil || *artifact.Profile.DebugAssertions {
				return "", errors.New("Cargo benchmark artifact is not optimized without debug assertions")
			}
		}
		if executable != "" || *artifact.Executable == "" {
			return "", errors.New("ambiguous or empty Cargo executable")
		}
		executable = *artifact.Executable
	}
	if executable == "" {
		return "", fmt.Errorf("Cargo executable missing for %s", target.Name)
	}
	return executable, nil
}

func buildCargoExecutable(cmd *exec.Cmd, target cargoTarget) (string, error) {
	output, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	if err = cmd.Start(); err != nil {
		return "", err
	}
	executable, parseError := readCargoExecutable(output, target)
	// A malformed stream still drains the real child before waiting for exit.
	_, drainError := io.Copy(io.Discard, output)
	if err = errors.Join(parseError, drainError, cmd.Wait()); err != nil {
		return "", err
	}
	return executable, nil
}

func TestCargoExecutableUsesReportedTargetAndRejectsAmbiguity(t *testing.T) {
	const record = `{"reason":"compiler-artifact","target":{"name":"weaver-server","kind":["bin"]},"profile":{"test":false},"executable":"/custom target/release/weaver-server"}`
	target := cargoTarget{Name: "weaver-server", Kind: "bin"}
	for _, tc := range []struct {
		name, stream string
		valid        bool
	}{
		{"reported path", record + "\n" + `{"reason":"build-finished","success":true}`, true},
		{"duplicate", record + "\n" + record, false},
		{"wrong target", strings.ReplaceAll(record, "weaver-server", "another-server"), false},
		{"wrong kind", strings.ReplaceAll(record, `"bin"`, `"lib"`), false},
		{"test artifact", strings.ReplaceAll(record, "false", "true"), false},
		{"missing executable", strings.ReplaceAll(record, `"/custom target/release/weaver-server"`, "null"), false},
		{"empty executable", strings.ReplaceAll(record, `"/custom target/release/weaver-server"`, `""`), false},
		{"truncated after artifact", record + "\n{", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path, err := readCargoExecutable(strings.NewReader(tc.stream), target)
			if tc.valid {
				if err != nil || path != "/custom target/release/weaver-server" {
					t.Fatal(path, err)
				}
			} else if err == nil || path != "" {
				t.Fatal("invalid Cargo stream selected an executable", path, err)
			}
		})
	}
}

func FuzzCargoExecutablePreservesReportedPath(f *testing.F) {
	f.Add("/custom target/debug/weaver-server", false)
	f.Add("/quoted\" target/release/weaver-server", true)
	f.Fuzz(func(t *testing.T, path string, duplicate bool) {
		if !utf8.ValidString(path) {
			t.Skip("Cargo JSON paths are UTF-8")
		}
		encoded, err := json.Marshal(path)
		if err != nil {
			t.Fatal(err)
		}
		record := `{"reason":"compiler-artifact","target":{"name":"weaver-server","kind":["bin"]},"executable":` + string(encoded) + `}`
		stream := record
		if duplicate {
			stream += "\n" + record
		}
		actual, err := readCargoExecutable(strings.NewReader(stream), cargoTarget{Name: "weaver-server", Kind: "bin"})
		if path == "" || duplicate {
			if err == nil || actual != "" {
				t.Fatal("invalid stream selected an executable", actual, err)
			}
		} else if err != nil || actual != path {
			t.Fatal("Cargo path changed", actual, path, err)
		}
	})
}

// The existing deployment inputs select the release Scheme graph. Ordinary
// qualification keeps its debug-only producer and the Cargo artifact check.
const providerSchemeQualificationFeatures = "arrow,governance-qualification"
const providerSchemeReleaseFeatures = "arrow,scheme-program"

func providerCargoBuildArgs(features, benchmark string, lookup func(string) (string, bool)) ([]string, bool, error) {
	application, applicationSet := lookup("WEAVER_GOVERNANCE_APPLICATION")
	source, sourceSet := lookup("WEAVER_GOVERNANCE_APPLICATION_SOURCE")
	optimized := benchmark != ""
	if applicationSet || sourceSet {
		if !applicationSet || !sourceSet || application == "" || source == "" {
			return nil, false, errors.New("release Scheme integration requires both application inputs")
		}
		if features != providerSchemeQualificationFeatures {
			return nil, false, errors.New("release Scheme integration requires the schemeintegration tag")
		}
		features = providerSchemeReleaseFeatures
		optimized = true
	} else if optimized && features == providerSchemeQualificationFeatures {
		return nil, false, errors.New("release Scheme integration requires an explicit application")
	}
	if features == providerSchemeQualificationFeatures {
		return append(devrunner.SchemeQualificationCargoArgs(), "--no-run", "--message-format=json-render-diagnostics"), false, nil
	}
	args := []string{"build", "-p", "weaver-server", "--bin", "weaver-server", "--features", features, "--locked", "--offline", "--message-format=json-render-diagnostics"}
	if optimized {
		args = append(args, "--release")
	}
	return args, optimized, nil
}

func TestProviderBenchmarkUsesOptimizedRustImage(t *testing.T) {
	for _, benchmark := range []string{"", "^BenchmarkGatewayStreamingPair$", "."} {
		args, optimized, err := providerCargoBuildArgs("arrow", benchmark, func(string) (string, bool) { return "", false })
		if err != nil || optimized != (benchmark != "") || slices.Contains(args, "--release") != optimized {
			t.Fatal("incorrect runtime measurement profile", args)
		}
		for _, required := range []string{"--locked", "--offline", "--message-format=json-render-diagnostics"} {
			if !slices.Contains(args, required) {
				t.Fatal("lost source/artifact boundary", args)
			}
		}
	}
}

func TestSchemeIntegrationReleaseRequiresExplicitApplication(t *testing.T) {
	const module = "WEAVER_GOVERNANCE_APPLICATION"
	const source = "WEAVER_GOVERNANCE_APPLICATION_SOURCE"
	for _, tc := range []struct {
		name, features, benchmark string
		env                       map[string]string
		wantFeatures              string
		optimized                 bool
	}{
		{name: "release application", features: "arrow,governance-qualification", env: map[string]string{module: "weaver/provider", source: "/provider.ss"}, wantFeatures: "arrow,scheme-program", optimized: true},
		{name: "missing binding", features: "arrow,governance-qualification", env: map[string]string{module: "weaver/provider"}},
		{name: "empty binding", features: "arrow,governance-qualification", env: map[string]string{module: "weaver/provider", source: ""}},
		{name: "qualification benchmark", features: "arrow,governance-qualification", benchmark: "."},
		{name: "missing tag", features: "arrow", env: map[string]string{module: "weaver/provider", source: "/provider.ss"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			args, optimized, err := providerCargoBuildArgs(tc.features, tc.benchmark, func(key string) (string, bool) {
				value, exists := tc.env[key]
				return value, exists
			})
			if tc.wantFeatures == "" {
				if err == nil || len(args) != 0 {
					t.Fatal("invalid selection emitted a Cargo command", args, err)
				}
				return
			}
			if err != nil || optimized != tc.optimized || slices.Contains(args, "--release") != optimized ||
				!slices.Contains(args, tc.wantFeatures) || (optimized && slices.Contains(args, "arrow,governance-qualification")) {
				t.Fatal("invalid Scheme integration build selection", args, err)
			}
		})
	}
}

func TestSchemeDebugUsesPreparedCargoQualificationGraph(t *testing.T) {
	args, optimized, err := providerCargoBuildArgs(providerSchemeQualificationFeatures, "", func(string) (string, bool) { return "", false })
	want := append(devrunner.SchemeQualificationCargoArgs(), "--no-run", "--message-format=json-render-diagnostics")
	if err != nil || optimized || !slices.Equal(args, want) {
		t.Fatal("debug Scheme integration does not share the prepared Cargo graph", args, err)
	}
}

func TestCargoOptimizedArtifactRequiresActualProfile(t *testing.T) {
	const record = `{"reason":"compiler-artifact","target":{"name":"gateway","kind":["bench"]},"profile":{"test":true,"opt_level":"3","debug_assertions":false},"executable":"/reported/gateway"}`
	for _, tc := range []struct {
		text  string
		valid bool
	}{
		{record, true}, {strings.Replace(record, `"opt_level":"3"`, `"opt_level":"0"`, 1), false},
		{strings.Replace(record, `"debug_assertions":false`, `"debug_assertions":true`, 1), false},
		{strings.Replace(record, `,"debug_assertions":false`, "", 1), false},
	} {
		_, err := readCargoExecutable(strings.NewReader(tc.text), cargoTarget{Name: "gateway", Kind: "bench", Test: true, Optimized: true})
		if (err == nil) != tc.valid {
			t.Fatal("optimized profile admission", err)
		}
	}
}
