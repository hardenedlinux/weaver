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
	for _, path := range []string{"Cargo.toml", "Cargo.lock", "go.work", "go/go.mod", "go/go.sum", "rustfmt.toml", "clippy.toml",
		"devenv.nix", "devenv.lock", "dev/toolchains/go/default.nix", "dev/toolchains/go/fuzz-parent-deadline.patch",
		"devenv.yaml", ".envrc", ".github/workflows/assurance.yml",
		"dev/proofs/lean/RuntimeAdmission.lean", "dev/proofs/lean/StreamingExecution.lean", "dev/proofs/lean/ProviderRpc.lean", "dev/proofs/lean/PublicationRecovery.lean",
		"dev/proofs/quint/RuntimeAdmission.qnt", "dev/proofs/quint/StreamingExecution.qnt", "dev/proofs/quint/RuntimeLifecycle.qnt", "dev/proofs/quint/ProviderRpc.qnt", "dev/proofs/quint/DispatchCancellation.qnt", "dev/proofs/quint/NativeAdmission.qnt", "dev/proofs/quint/ConnectionAdmission.qnt", "dev/proofs/quint/SourceIngress.qnt", "dev/proofs/quint/PublicationRecovery.qnt", "dev/proofs/quint/SourceOwner.qnt",
		"dev/proofs/quint/ReleaseBinding.qnt",
		"dev/proofs/quint/ProviderProfile.qnt",
		"dev/proofs/quint/GatewayComposition.qnt",
		"dev/proofs/cedar/lakefile.toml", "dev/proofs/cedar/lake-manifest.json", "dev/proofs/cedar/lean-toolchain", "dev/proofs/cedar/WeaverPolicyBridge.lean"} {
		if err := add(filepath.Join(root, path)); err != nil {
			return nil, err
		}
	}
	if _, err := os.Stat(filepath.Join(root, "go.work.sum")); err == nil {
		if err := add(filepath.Join(root, "go.work.sum")); err != nil {
			return nil, err
		}
	}
	for _, directory := range []string{"crates", "go", "api", "dev/models", "dev/policies", "dev/benchmarks"} {
		err := filepath.WalkDir(filepath.Join(root, directory), func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() {
				return nil
			}
			switch filepath.Ext(path) {
			case ".go", ".rs", ".toml", ".json", ".yaml", ".yml", ".proto", ".sysml", ".cedar":
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
