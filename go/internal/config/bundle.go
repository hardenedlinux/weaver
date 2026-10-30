package config

import (
	"bytes"
	"encoding/json"
	"errors"
	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/routing"
	"gopkg.in/yaml.v3"
	"io"
	"strconv"
)

// Bundle is trusted source configuration, not authority supplied by an agent.
type Bundle struct {
	Governance  Governance        `json:"governance"`
	Tasks       []v1.Task         `json:"tasks"`
	Plans       []v1.ProviderPlan `json:"plans"`
	Publication v1.Publication    `json:"publication"`
}

// Governance is the native governor's selected handoff, not a runtime permit.
// This source profile publishes one original family per governor handoff.
type Governance struct {
	Schema    string   `json:"schema"`
	Family    string   `json:"family"`
	OpenNodes []string `json:"open_nodes"`
}

func DecodeBundle(data []byte, format ProfileFormat) (Bundle, error) {
	var zero Bundle
	if len(data) == 0 || len(data) > 8<<20 {
		return zero, errors.New("source bundle bound")
	}
	if format == ProfileYAML {
		decoder := yaml.NewDecoder(bytes.NewReader(data))
		var doc, tail yaml.Node
		if err := decoder.Decode(&doc); err != nil {
			return zero, err
		}
		if decoder.Decode(&tail) != io.EOF {
			return zero, errors.New("one source document required")
		}
		value, err := bundleNode(&doc, 0)
		if err != nil {
			return zero, err
		}
		data, err = json.Marshal(value)
		if err != nil {
			return zero, err
		}
	} else if format != ProfileJSON {
		return zero, errors.New("source format")
	}
	bundle, err := v1.Decode[Bundle](data)
	if err != nil {
		return zero, err
	}
	if err = bundle.Validate(); err != nil {
		return zero, err
	}
	return bundle, nil
}

func (b Bundle) Validate() error {
	if len(b.Tasks) != 1 || len(b.Plans) == 0 || len(b.Plans) > 64 {
		return errors.New("source inventory bound")
	}
	if b.Governance.Schema != "agentic-ai-lab.loop-governor.v1" || b.Governance.Family != b.Tasks[0].Family || len(b.Governance.OpenNodes) != len(b.Plans) || len(b.Tasks[0].Nodes) != len(b.Plans) {
		return errors.New("Governor source handoff binding")
	}
	selected := map[string]bool{}
	for _, node := range b.Governance.OpenNodes {
		if node == "" || selected[node] {
			return errors.New("governor node identity")
		}
		selected[node] = true
	}
	for _, node := range b.Tasks[0].Nodes {
		if !selected[node] {
			return errors.New("task exceeds governor selection")
		}
		delete(selected, node)
	}
	if len(selected) != 0 {
		return errors.New("duplicate task node")
	}
	for _, node := range b.Governance.OpenNodes {
		selected[node] = true
	}
	if _, err := b.Publication.Digest(); err != nil {
		return err
	}
	view := b.View()
	tasks := map[string]v1.Task{}
	for _, task := range b.Tasks {
		if _, exists := tasks[task.Family]; exists || task.Family == "" || task.Principal == "" {
			return errors.New("duplicate or invalid source family")
		}
		tasks[task.Family] = task
	}
	seen := map[[2]string]bool{}
	for _, plan := range b.Plans {
		key := [2]string{plan.Family, plan.Node}
		task, ok := tasks[plan.Family]
		if !ok || seen[key] || !selected[plan.Node] {
			return errors.New("unknown or duplicate source operation")
		}
		if _, err := routing.CompileProvider(task, plan, view); err != nil {
			return err
		}
		seen[key] = true
	}
	return nil
}

func (b Bundle) View() v1.View {
	revision := uint64(0)
	if b.Publication.ExpectedRevision != nil {
		revision = *b.Publication.ExpectedRevision + 1
	}
	return v1.View{Revision: revision, Fence: b.Publication.Fence}
}

func bundleNode(n *yaml.Node, depth int) (any, error) {
	if depth > 32 || n.Anchor != "" || n.Kind == yaml.AliasNode {
		return nil, errors.New("source YAML structure")
	}
	switch n.Kind {
	case yaml.DocumentNode:
		if len(n.Content) == 1 {
			return bundleNode(n.Content[0], depth+1)
		}
	case yaml.MappingNode:
		if n.Tag != "!!map" {
			break
		}
		out := map[string]any{}
		for i := 0; i < len(n.Content); i += 2 {
			k := n.Content[i]
			if k.Kind != yaml.ScalarNode || k.Tag != "!!str" || k.Anchor != "" {
				return nil, errors.New("source YAML key")
			}
			if _, ok := out[k.Value]; ok {
				return nil, errors.New("duplicate source YAML key")
			}
			v, err := bundleNode(n.Content[i+1], depth+1)
			if err != nil {
				return nil, err
			}
			out[k.Value] = v
		}
		return out, nil
	case yaml.SequenceNode:
		if n.Tag != "!!seq" {
			break
		}
		out := make([]any, 0, len(n.Content))
		for _, child := range n.Content {
			v, err := bundleNode(child, depth+1)
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
		return out, nil
	case yaml.ScalarNode:
		switch n.Tag {
		case "!!str":
			return n.Value, nil
		case "!!null":
			if n.Value == "null" {
				return nil, nil
			}
		case "!!bool":
			if n.Value == "true" {
				return true, nil
			}
			if n.Value == "false" {
				return false, nil
			}
		case "!!int":
			v, err := strconv.ParseUint(n.Value, 10, 64)
			if err == nil && strconv.FormatUint(v, 10) == n.Value {
				return v, nil
			}
		}
	}
	return nil, errors.New("unsupported source YAML value")
}
