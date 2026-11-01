package devrunner

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/Open-MBEE/OpenSysML/client/opensysml"
)

type ModelViewCapture struct {
	ModelHash string                             `json:"modelHash"`
	Sources   map[string]string                  `json:"sources"`
	Views     map[string]*opensysml.RenderedView `json:"views"`
}

// MarshalJSON uses the official SDK's lower-camel-case transport field names.
// Values and view identities are preserved; no SysML interpretation occurs here.
func (capture ModelViewCapture) MarshalJSON() ([]byte, error) {
	views := make(map[string]json.RawMessage, len(capture.Views))
	for name, view := range capture.Views {
		raw, err := json.Marshal(view)
		if err != nil {
			return nil, err
		}
		encoded, err := sdkJSONFields(raw)
		if err != nil {
			return nil, err
		}
		views[name] = encoded
	}
	return json.Marshal(struct {
		ModelHash string                     `json:"modelHash"`
		Sources   map[string]string          `json:"sources"`
		Views     map[string]json.RawMessage `json:"views"`
	}{capture.ModelHash, capture.Sources, views})
}

func sdkJSONFields(raw json.RawMessage) (json.RawMessage, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return nil, fmt.Errorf("empty SDK JSON value")
	}
	switch raw[0] {
	case '{':
		var source map[string]json.RawMessage
		if err := json.Unmarshal(raw, &source); err != nil {
			return nil, err
		}
		result := make(map[string]json.RawMessage, len(source))
		for key, value := range source {
			name := key
			if key == "ID" {
				name = "id"
			} else if len(key) > 0 {
				name = strings.ToLower(key[:1]) + key[1:]
			}
			if _, exists := result[name]; exists {
				return nil, fmt.Errorf("conflicting SDK transport field: %s", name)
			}
			encoded, err := sdkJSONFields(value)
			if err != nil {
				return nil, err
			}
			result[name] = encoded
		}
		return json.Marshal(result)
	case '[':
		var values []json.RawMessage
		if err := json.Unmarshal(raw, &values); err != nil {
			return nil, err
		}
		for index, value := range values {
			encoded, err := sdkJSONFields(value)
			if err != nil {
				return nil, err
			}
			values[index] = encoded
		}
		return json.Marshal(values)
	default:
		return raw, nil
	}
}

// CaptureModelViews uses the existing SDK's parser, semantic analysis, view
// selection and rendering. It never interprets SysML or fabricates a diagram.
func CaptureModelViews(ctx context.Context, root string) (*ModelViewCapture, error) {
	paths, err := filepath.Glob(filepath.Join(root, "dev/sysml/*.sysml"))
	if err != nil {
		return nil, err
	}
	paths = append(paths, filepath.Join(root, "Project.sysml"))
	slices.Sort(paths)
	capture := &ModelViewCapture{Sources: map[string]string{}, Views: map[string]*opensysml.RenderedView{}}
	documents := make([]opensysml.Document, 0, len(paths))
	for _, path := range paths {
		info, err := os.Lstat(path)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() {
			return nil, fmt.Errorf("model source must be a regular file: %s", path)
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		sum := sha256.Sum256(body)
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return nil, err
		}
		capture.Sources[filepath.ToSlash(relative)] = hex.EncodeToString(sum[:])
		documents = append(documents, opensysml.Source(filepath.ToSlash(relative), string(body)))
	}
	client, err := opensysml.New(opensysml.WithCacheSize(1))
	if err != nil {
		return nil, err
	}
	defer client.Close()
	model, err := client.ParseDocuments(ctx, documents, opensysml.WithStrictConformance())
	if err != nil {
		return nil, err
	}
	if !model.OK() {
		return nil, fmt.Errorf("SysML model invalid: %v", model.Errors())
	}
	capture.ModelHash = model.Hash
	views, err := client.Query(ctx, model, opensysml.Query{Where: opensysml.Equals("@type", "ViewUsage")})
	if err != nil {
		return nil, err
	}
	for _, view := range views {
		rendered, err := client.RenderView(ctx, model, view.ID)
		if err != nil {
			return nil, fmt.Errorf("render SysML view %s: %w", view.ID, err)
		}
		capture.Views[view.ID] = rendered
	}
	return capture, nil
}

func publishModelViews(ctx context.Context, root string) (string, error) {
	capture, err := CaptureModelViews(ctx, root)
	if err != nil {
		return "", err
	}
	bytes, err := json.Marshal(capture)
	if err != nil {
		return "", err
	}
	dir := filepath.Join(root, ".cache/d2")
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", err
	}
	file, err := os.CreateTemp(dir, "model-views-*.json")
	if err != nil {
		return "", err
	}
	defer os.Remove(file.Name())
	if _, err := file.Write(bytes); err != nil {
		file.Close()
		return "", err
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(file.Name(), filepath.Join(dir, "model-views.json")); err != nil {
		return "", err
	}
	sum := sha256.Sum256(bytes)
	return hex.EncodeToString(sum[:]), nil
}
