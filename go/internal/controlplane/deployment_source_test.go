// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package controlplane

import (
	"context"
	"github.com/HardenedLinux/weaver/go/internal/gatewayclient"
	"reflect"
	"testing"
)

func TestUnavailableDeploymentProducerCannotUseDataFallback(t *testing.T) {
	artifact, bundle := artifactFixture(t)
	rpc := &sourceRPC{artifact: artifact, publication: bundle.Publication, failCompile: true}
	client := &gatewayclient.Client{RPC: rpc, Token: "source-token"}
	// Even accidental internal coexistence cannot turn failure into fallback.
	input := deploymentSource{producer: "approved", bundle: bundle}
	_, err := input.bootstrap(context.Background(), client, client)
	if err == nil || !reflect.DeepEqual(rpc.calls, []string{"compile"}) {
		t.Fatal("producer failure fell back or published", rpc.calls, err)
	}
}

func FuzzDeploymentSourceHasOneOwner(f *testing.F) {
	f.Add(uint8(1), "approved-AA", "source.ss")
	f.Add(uint8(2), "", "source.yaml")
	f.Add(uint8(3), "approved-AA", "source.json")
	f.Fuzz(func(t *testing.T, mask uint8, name, path string) {
		values := map[string]string{}
		if mask&1 != 0 {
			values["WEAVER_CONTROL_PRODUCER"] = name
		}
		if mask&2 != 0 {
			values["WEAVER_CONTROL_CONFIG"] = path
		}
		input, err := selectDeploymentSource(func(key string) (string, bool) { value, ok := values[key]; return value, ok })
		if mask&3 == 0 || mask&3 == 3 {
			if err == nil {
				t.Fatal("missing or ambiguous source admitted")
			}
			return
		}
		if err != nil {
			return
		}
		if (input.producer == "") == (input.path == "") {
			t.Fatal("source ownership not exclusive")
		}
		if mask&1 != 0 && (input.producer != name || input.path != "") {
			t.Fatal("producer changed or file fallback admitted")
		}
		if mask&2 != 0 && (input.path != path || input.producer != "") {
			t.Fatal("file changed or producer fabricated")
		}
	})
}

func TestSchemeDeploymentCannotStartCompilerProcess(t *testing.T) {
	for _, path := range []string{"source.ss", "source.scm", "source.SS", "source.SCM"} {
		_, err := selectDeploymentSource(func(key string) (string, bool) { return path, key == "WEAVER_CONTROL_CONFIG" })
		if err == nil {
			t.Fatal("Scheme file admitted as runtime compiler request", path)
		}
	}
}
