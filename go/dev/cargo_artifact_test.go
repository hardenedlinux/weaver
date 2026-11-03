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
)

type cargoTarget struct {
	Name string
	Kind string
	Test bool
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
				Test bool `json:"test"`
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

// Standard Go benchmark selection also selects an optimized provider image.
// Ordinary integration tests keep their default debug assertions. Artifact
// paths still come from Cargo JSON, never a guessed target/profile directory.
func providerCargoBuildArgs(features, benchmark string) []string {
	args := []string{"build", "-p", "weaver-server", "--bin", "weaver-server", "--features", features, "--locked", "--offline", "--message-format=json-render-diagnostics"}
	if benchmark != "" {
		args = append(args, "--release")
	}
	return args
}

func TestProviderBenchmarkUsesOptimizedRustImage(t *testing.T) {
	for _, benchmark := range []string{"", "^BenchmarkGatewayStreamingPair$", "."} {
		args := providerCargoBuildArgs("arrow", benchmark)
		if slices.Contains(args, "--release") != (benchmark != "") {
			t.Fatal("incorrect runtime measurement profile", args)
		}
		for _, required := range []string{"--locked", "--offline", "--message-format=json-render-diagnostics"} {
			if !slices.Contains(args, required) {
				t.Fatal("lost source/artifact boundary", args)
			}
		}
	}
}
