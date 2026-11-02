package devrunner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// One typed handoff shared by preparation and currentness checks.
type schemeLinkReceipt struct {
	Environment       map[string]string `json:"environment"`
	SourceHeads       map[string]string `json:"source_heads"`
	DependencyLibrary string            `json:"dependency_library"`
	SourceRoot        string            `json:"source_root"`
	SourceHashes      map[string]string `json:"source_hashes"`
	PooSource         string            `json:"poo_source"`
}

func schemeSourceDigest(hashes map[string]string) (string, error) {
	canonical, err := json.Marshal(hashes)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(canonical)
	return hex.EncodeToString(digest[:]), nil
}

func checkInstalledSchemeHeads(ctx context.Context, prefix string, heads map[string]string) error {
	for _, name := range []string{"gebril-yuanxu", "gerbil-poo"} {
		installed := filepath.Join(prefix, "pkg", "github.com", "tao3k", name)
		cmd := exec.CommandContext(ctx, "git", "-C", installed, "rev-parse", "HEAD")
		data, err := cmd.Output()
		if err != nil {
			return fmt.Errorf("read installed %s identity: %w", name, err)
		}
		if strings.TrimSpace(string(data)) != heads[name] {
			return fmt.Errorf("installed %s differs from the declared source cohort: got %s want %s", name, strings.TrimSpace(string(data)), heads[name])
		}
	}
	return nil
}

func checkLinkedSchemeHeads(ctx context.Context, source, poo string, heads map[string]string) error {
	if len(heads) != 3 || source == "" || poo == "" {
		return errors.New("linked Scheme source identity incomplete")
	}
	for path, name := range map[string]string{source: "agentic-ai-lab", filepath.Join(source, "core"): "gebril-yuanxu", poo: "gerbil-poo"} {
		cmd := exec.CommandContext(ctx, "git", "-C", path, "rev-parse", "HEAD")
		data, err := cmd.Output()
		if err != nil || strings.TrimSpace(string(data)) != heads[name] {
			return fmt.Errorf("linked source revision changed: %s: %w", name, errors.Join(err, errors.New("source identity mismatch")))
		}
	}
	return nil
}

// Keep dependency preparation inside the existing verification owner and compact
// receipt. This invokes no alternative compiler/test entry and adds no timeout.
func prepareSchemeStage(ctx context.Context, root, directory string, config Config, receipt *Receipt) (map[string]string, Result) {
	result := Result{Name: "scheme-preparation", Binary: "internal/PrepareScheme", Status: "FAIL", Log: "scheme-preparation.log"}
	started := time.Now()
	log, err := os.OpenFile(filepath.Join(directory, result.Log), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		result.Error = err.Error()
		return nil, result
	}
	settings, err := PrepareScheme(ctx, root, config.SchemeSource, config.SchemePoo, config.SchemeLibrary, receipt, log)
	if err != nil {
		fmt.Fprintln(log, err)
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code := exit.ExitCode()
			result.ExitCode = &code
		}
	}
	err = errors.Join(err, log.Close(), ctx.Err())
	result.Duration = time.Since(started).String()
	if err == nil {
		result.Status = "PASS"
	} else {
		result.Error = err.Error()
		if ctx.Err() != nil {
			result.Status = "CANCELLED"
		}
	}
	return settings, result
}
