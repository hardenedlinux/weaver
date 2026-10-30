package devrunner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// PrepareScheme uses development links without changing either source checkout,
// global Gerbil packages, or existing dependency pins. No package is uninstalled.
func PrepareScheme(ctx context.Context, root, source, poo, library string, output io.Writer) (map[string]string, error) {
	compiler := os.Getenv("WEAVER_CONTROL_SCHEME_COMPILER")
	if !filepath.IsAbs(compiler) || source == "" || poo == "" {
		return nil, errors.New("explicit Scheme compiler, source checkout and dependency library required")
	}
	if !filepath.IsAbs(source) {
		source = filepath.Join(root, source)
	}
	if !filepath.IsAbs(poo) {
		poo = filepath.Join(root, poo)
	}
	source, err := filepath.EvalSymlinks(source)
	if err != nil {
		return nil, err
	}
	if library != "" {
		library, err = filepath.Abs(library)
		if err != nil {
			return nil, err
		}
		if info, err := os.Stat(library); err != nil || !info.IsDir() {
			return nil, errors.New("invalid additional Scheme dependency library")
		}
	}
	core := filepath.Join(source, "core")
	poo, err = filepath.EvalSymlinks(poo)
	if err != nil {
		return nil, err
	}
	heads := map[string]string{}
	for path, name := range map[string]string{source: "agentic-ai-lab", core: "gebril-yuanxu", poo: "gerbil-poo"} {
		cmd := exec.CommandContext(ctx, "git", "-C", path, "remote", "get-url", "origin")
		data, err := cmd.Output()
		if err != nil {
			return nil, err
		}
		remote := strings.TrimSuffix(strings.TrimSpace(string(data)), ".git")
		if !strings.HasSuffix(remote, "/tao3k/"+name) && !strings.HasSuffix(remote, ":tao3k/"+name) {
			return nil, fmt.Errorf("unexpected source remote for %s", name)
		}
		cmd = exec.CommandContext(ctx, "git", "-C", path, "rev-parse", "HEAD")
		data, err = cmd.Output()
		if err != nil {
			return nil, err
		}
		heads[name] = strings.TrimSpace(string(data))
	}
	declared, err := DeclaredPooRevision(core)
	if err != nil {
		return nil, err
	}
	if declared != heads["gerbil-poo"] {
		return nil, errors.New("Gerbil POO source must match Core's declared exact dependency pin")
	}
	directory, err := os.MkdirTemp("", "weaver-scheme-*")
	if err != nil {
		return nil, err
	}
	complete := false
	defer func() {
		if !complete {
			os.RemoveAll(directory)
		}
	}()
	if library == "" {
		library = filepath.Join(directory, "dependencies")
		if err := os.MkdirAll(library, 0700); err != nil {
			return nil, err
		}
	}
	lib := filepath.Join(directory, "lib")
	if err = os.MkdirAll(lib, 0700); err != nil {
		return nil, err
	}
	sources := filepath.Join(directory, "source")
	if err = os.MkdirAll(sources, 0700); err != nil {
		return nil, err
	}
	settings := map[string]string{"GERBIL_PATH": directory, "GERBIL_LOADPATH": strings.Join([]string{lib, sources, library}, string(os.PathListSeparator)), "WEAVER_CONTROL_SCHEME_COMPILER": compiler, "WEAVER_SCHEME_POO_SOURCE": poo, "WEAVER_SCHEME_CORE_SOURCE": core}
	settings["WEAVER_POLICY_PKG_CONFIG"] = filepath.Join(lib, "pkgconfig", "weaver-policy-ffi.pc")
	settings["WEAVER_POLICY_PKG_CONFIG_PACKAGE"] = strings.TrimSuffix(filepath.Base(settings["WEAVER_POLICY_PKG_CONFIG"]), ".pc")
	settings["PKG_CONFIG_PATH"] = filepath.Dir(settings["WEAVER_POLICY_PKG_CONFIG"])
	if inherited := os.Getenv("PKG_CONFIG_PATH"); inherited != "" {
		settings["PKG_CONFIG_PATH"] += string(os.PathListSeparator) + inherited
	}
	for path, name := range map[string]string{source: "agentic-ai-lab", core: "gebril-yuanxu", poo: "gerbil-poo"} {
		cmd := exec.CommandContext(ctx, filepath.Join(filepath.Dir(compiler), "gxpkg"), "link", "-g", "github.com/tao3k/"+name, path)
		cmd.Env = Environment(settings)
		cmd.Stdout, cmd.Stderr = output, output
		if err = cmd.Run(); err != nil {
			return nil, err
		}
	}
	settings["WEAVER_SCHEME_AGENTIC_SOURCE"] = source
	for name, path := range map[string]string{"agentic-ai-lab": source, "yuanxu": core} {
		if err = os.Symlink(path, filepath.Join(sources, name)); err != nil {
			return nil, err
		}
	}
	// Core declares this public prelude identity in prelude.ss; it is part of
	// Agentic AI Lab's inherited source closure, not a second Weaver dependency.
	if err := os.MkdirAll(filepath.Join(sources, "tao3k"), 0700); err != nil {
		return nil, err
	}
	if err := os.Symlink(core, filepath.Join(sources, "tao3k", "yuanxu")); err != nil {
		return nil, err
	}
	if err = os.MkdirAll(filepath.Join(sources, "clan"), 0700); err != nil {
		return nil, err
	}
	if err = os.Symlink(poo, filepath.Join(sources, "clan", "poo")); err != nil {
		return nil, err
	}
	if err = os.MkdirAll(filepath.Join(sources, "hardenedlinux"), 0700); err != nil {
		return nil, err
	}
	if err = os.Symlink(root, filepath.Join(sources, "hardenedlinux", "weaver")); err != nil {
		return nil, err
	}
	hashes, err := schemeSourceHashes(source, poo)
	if err != nil {
		return nil, err
	}
	receipt := struct {
		Environment       map[string]string `json:"environment"`
		SourceHeads       map[string]string `json:"source_heads"`
		DependencyLibrary string            `json:"dependency_library"`
		SourceRoot        string            `json:"source_root"`
		SourceHashes      map[string]string `json:"source_hashes"`
		PooSource         string            `json:"poo_source"`
	}{settings, heads, library, source, hashes, poo}
	data, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return nil, err
	}
	if err = os.WriteFile(filepath.Join(directory, "environment.json"), data, 0600); err != nil {
		return nil, err
	}
	fmt.Fprintln(output, "Scheme development links:", filepath.Join(directory, "environment.json"))
	settings["WEAVER_SCHEME_LINK_RECEIPT"] = filepath.Join(directory, "environment.json")
	complete = true
	return settings, nil
}

// DeclaredPooRevision reads the inherited package declaration, rather than
// maintaining a second CI version registry beside Agentic AI Lab's gitlink.
func DeclaredPooRevision(core string) (string, error) {
	data, err := os.ReadFile(filepath.Join(core, "gerbil.pkg"))
	if err != nil {
		return "", err
	}
	matches := regexp.MustCompile(`"github\.com/tao3k/gerbil-poo@([a-f0-9]{40})"`).FindAllSubmatch(data, -1)
	if len(matches) != 1 {
		return "", errors.New("Core must declare one exact Gerbil POO revision")
	}
	return string(matches[0][1]), nil
}

func schemeSourceHashes(source, poo string) (map[string]string, error) {
	var err error
	source, err = filepath.EvalSymlinks(source)
	if err != nil {
		return nil, err
	}
	if poo != "" {
		poo, err = filepath.EvalSymlinks(poo)
		if err != nil {
			return nil, err
		}
	}
	hashes := map[string]string{}
	for _, directory := range []string{"modules", "core"} {
		err := filepath.WalkDir(filepath.Join(source, directory), func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() {
				if strings.HasPrefix(entry.Name(), ".") {
					return filepath.SkipDir
				}
				return nil
			}
			// gerbil build regenerates this SDK-owned version output. It is not
			// a handwritten governance source or a second package manifest.
			if path == filepath.Join(source, "core", "manifest.ss") {
				return nil
			}
			switch filepath.Ext(path) {
			case ".ss", ".scm", ".inc", ".pkg", ".h":
				data, err := os.ReadFile(path)
				if err != nil {
					return err
				}
				sum := sha256.Sum256(data)
				relative, err := filepath.Rel(source, path)
				if err != nil {
					return err
				}
				hashes[relative] = hex.EncodeToString(sum[:])
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	if poo != "" {
		err := filepath.WalkDir(poo, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() {
				if strings.HasPrefix(entry.Name(), ".") {
					return filepath.SkipDir
				}
				return nil
			}
			if path == filepath.Join(poo, "manifest.ss") {
				return nil
			}
			switch filepath.Ext(path) {
			case ".ss", ".scm", ".inc", ".pkg", ".h":
				data, err := os.ReadFile(path)
				if err != nil {
					return err
				}
				sum := sha256.Sum256(data)
				relative, err := filepath.Rel(poo, path)
				if err != nil {
					return err
				}
				hashes["gerbil-poo/"+relative] = hex.EncodeToString(sum[:])
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	return hashes, nil
}

// External linked sources have their own receipt; they cannot be admitted as
// committed Weaver blobs. Native dependency-library qualification is separate.
func schemeSourceCurrentness(directory, name string) Result {
	result := Result{Name: name, Binary: "internal/linked-source-sha256", Status: "FAIL", Log: name + ".log"}
	data, err := os.ReadFile(os.Getenv("WEAVER_SCHEME_LINK_RECEIPT"))
	var receipt struct {
		SourceRoot   string            `json:"source_root"`
		SourceHashes map[string]string `json:"source_hashes"`
		PooSource    string            `json:"poo_source"`
	}
	if err == nil {
		err = json.Unmarshal(data, &receipt)
	}
	if err == nil {
		var current map[string]string
		current, err = schemeSourceHashes(receipt.SourceRoot, receipt.PooSource)
		if err == nil && !maps.Equal(current, receipt.SourceHashes) {
			changed := []string{}
			for path, hash := range receipt.SourceHashes {
				if current[path] != hash {
					changed = append(changed, path)
				}
			}
			for path := range current {
				if _, exists := receipt.SourceHashes[path]; !exists {
					changed = append(changed, path)
				}
			}
			slices.Sort(changed)
			count := len(changed)
			changed = changed[:min(count, 8)]
			for index, path := range changed {
				changed[index] = path[:min(len(path), 160)]
			}
			err = fmt.Errorf("linked Scheme sources changed (%d): %s", count, strings.Join(changed, ", "))
		}
	}
	if err == nil {
		result.Status = "PASS"
	} else {
		result.Error = err.Error()
	}
	if err = os.WriteFile(filepath.Join(directory, result.Log), []byte(fmt.Sprintf("%s sources=%d %s\n", result.Status, len(receipt.SourceHashes), result.Error)), 0600); err != nil {
		result.Status = "FAIL"
		result.Error = err.Error()
	}
	return result
}
