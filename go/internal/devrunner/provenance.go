package devrunner

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// SourceInputs binds receipts to runtime, protocol, model, proof and benchmark inputs.
func SourceInputs(root string) (map[string]string, error) {
	result := map[string]string{}
	add := func(path string) error {
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("verification input must be a regular source file: %s", path)
		}
		bytes, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(bytes)
		result[filepath.ToSlash(relative)] = hex.EncodeToString(sum[:])
		return nil
	}
	for _, path := range []string{"Project.sysml", "README.org", ".gitignore", "Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "go/go.mod", "go/go.sum", "rustfmt.toml", "clippy.toml", "gerbil.pkg", "build.ss", "init.ss",
		"devenv.nix", "devenv.lock", "devenv.yaml", ".envrc"} {
		if err := add(filepath.Join(root, path)); err != nil {
			return nil, err
		}
	}
	// Inventory source owners, not a second hand-maintained list of proof roots.
	// Include Lake manifests/pins, but do not traverse its dependency/build cache.
	// Cache/toolchain integrity remains a separate qualification prerequisite.
	// Historical evidence and generated diagrams are not source inputs.
	for _, directory := range []string{"crates", "go", "proto", "scheme", "t", "prod", "dev/sysml", ".github", "docs", "dev/proofs/lean", "dev/proofs/quint", "dev/proofs/cedar"} {
		err := filepath.WalkDir(filepath.Join(root, directory), func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() {
				if entry.Name() == ".lake" {
					return fs.SkipDir
				}
				return nil
			}
			if entry.Type()&os.ModeSymlink != 0 {
				return fmt.Errorf("verification source alias is unsupported: %s", path)
			}
			if entry.Name() == "lean-toolchain" {
				return add(path)
			}
			switch filepath.Ext(path) {
			case ".go", ".rs", ".h", ".ss", ".pkg", ".toml", ".json", ".yaml", ".yml", ".proto", ".sysml", ".cedar", ".lean", ".qnt", ".org", ".d2":
				return add(path)
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return result, nil
}
func sourceCurrentness(root, directory string, before map[string]string) Result {
	after, err := SourceInputs(root)
	result := Result{Name: "source-currentness", Binary: "internal/source-sha256", Status: "PASS", Log: "source-currentness.log"}
	changes := []string{}
	if err != nil {
		result.Status = "FAIL"
		result.Error = err.Error()
	} else if !maps.Equal(before, after) {
		result.Status = "FAIL"
		result.Error = "verification inputs changed during execution"
		for name, hash := range before {
			if after[name] != hash {
				changes = append(changes, name)
			}
		}
		for name := range after {
			if _, ok := before[name]; !ok {
				changes = append(changes, name)
			}
		}
	}
	slices.Sort(changes)
	if err := os.WriteFile(filepath.Join(directory, result.Log), []byte(fmt.Sprintf("%s inputs=%d\n%s\n", result.Status, len(before), strings.Join(changes, "\n"))), 0600); err != nil {
		result.Status = "FAIL"
		result.Error = err.Error()
	}
	return result
}
