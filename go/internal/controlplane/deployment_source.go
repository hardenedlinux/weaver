// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package controlplane

import (
	"context"
	"errors"
	"path/filepath"
	"strings"

	"github.com/HardenedLinux/weaver/go/internal/config"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
)

// A deployment selects one source. An unavailable approved producer never
// falls back to a file, a compiler process or a fresh publication identity.
type deploymentSource struct {
	producer string
	path     string
	bundle   config.Bundle
}

func selectDeploymentSource(lookup func(string) (string, bool)) (deploymentSource, error) {
	producer, named := lookup("WEAVER_CONTROL_PRODUCER")
	path, file := lookup("WEAVER_CONTROL_CONFIG")
	if named == file {
		return deploymentSource{}, errors.New("exactly one control producer or configuration file required")
	}
	if named {
		if producer == "" || len(producer) > 128 || strings.ContainsAny(producer, "\x00\r\n") {
			return deploymentSource{}, errors.New("approved producer name required")
		}
		return deploymentSource{producer: producer}, nil
	}
	if path == "" {
		return deploymentSource{}, errors.New("configuration file required")
	}
	if ext := strings.ToLower(filepath.Ext(path)); ext == ".ss" || ext == ".scm" {
		return deploymentSource{}, errors.New("Scheme deployment requires an approved Rust producer")
	}
	return deploymentSource{path: path}, nil
}

func (input deploymentSource) bootstrap(ctx context.Context, source, operation *gatewayclient.Client) (*Gateway, error) {
	if input.producer != "" {
		return BootstrapProducer(ctx, source, operation, input.producer)
	}
	return Bootstrap(ctx, source, operation, input.bundle)
}
