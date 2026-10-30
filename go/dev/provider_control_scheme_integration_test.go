//go:build integration && schemeintegration && !windows

package dev

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// This test-only printer emits ordinary Scheme data, never governance semantics.
func schemeDatum(t testing.TB, value any) string {
	t.Helper()
	switch v := value.(type) {
	case string:
		return strconv.Quote(v)
	case json.Number:
		return string(v)
	case bool:
		if v {
			return "#t"
		}
		return "#f"
	case []any:
		parts := []string{"list"}
		for _, x := range v {
			parts = append(parts, schemeDatum(t, x))
		}
		return "(" + strings.Join(parts, " ") + ")"
	case map[string]any:
		keys := make([]string, 0, len(v))
		for key := range v {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		parts := []string{}
		for _, key := range keys {
			if v[key] == nil {
				continue
			} // Optional Record fields remain absent, never false/null aliases.
			parts = append(parts, "(cons (string->symbol "+strconv.Quote(key)+") "+schemeDatum(t, v[key])+")")
		}
		return "(object<-alist (list " + strings.Join(parts, " ") + "))"
	default:
		t.Fatalf("unsupported source fixture datum %T", value)
		return ""
	}
}
func nativeSource(t testing.TB, f *fixture, b config.Bundle, mode string) string {
	t.Helper()
	if os.Getenv("WEAVER_CONTROL_SCHEME_COMPILER") == "" || os.Getenv("GERBIL_PATH") == "" || os.Getenv("GERBIL_LOADPATH") == "" {
		t.Fatal("native Scheme qualification requires explicit compiler and isolated linked source/dependency paths")
	}
	data, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err = decoder.Decode(&value); err != nil {
		t.Fatal(err)
	}
	switch mode {
	case "policy":
		value["publication"].(map[string]any)["policy"] = "not a Cedar policy"
	case "denyall":
		value["publication"].(map[string]any)["policy"] = "forbid(principal,action,resource);"
	case "task-type":
		value["tasks"].([]any)[0].(map[string]any)["budget"] = "8"
	}
	// Only inert fixture data crosses this printer. Native constructors and
	// governance setup belong to the Scheme-owned integration fixture.
	source := fmt.Sprintf(`(import (only-in :clan/poo/object object<-alist) %q)
(emit-control-fixture %q %q %s %s %s)
`, filepath.Join(root(t), "t/fixtures/governed-control"), filepath.Join(root(t), "init.ss"), mode,
		schemeDatum(t, value["tasks"]), schemeDatum(t, value["plans"]), schemeDatum(t, value["publication"]))
	path := filepath.Join(f.directory, "governed-"+mode+".ss")
	if err = os.WriteFile(path, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestProviderControlNativeFfiValidationCannotAuthorize(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	b := controlBundle(t, f)
	c := newControlProcess(t, f, nativeSource(t, f, b, "denyall"))
	c.start(t)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if _, err := c.client.Execute(ctx, b.Plans[0], 0, 1, func(*pb.Event) error { t.Error("FFI success substituted for Cedar"); return nil }); status.Code(err) != codes.FailedPrecondition {
		t.Fatal("inert FFI validation authorized effect")
	}
	if f.primary.Load() != 0 || f.backup.Load() != 0 {
		t.Fatal("Cedar-denied request reached provider")
	}
}
func TestProviderControlNativeGovernorRevocationAndRestart(t *testing.T) {
	exerciseControl(t, "ss", func(t *testing.T, f *fixture, b config.Bundle) string { return nativeSource(t, f, b, "valid") })
}

func TestProviderControlNativeGovernorRejectsUnselectedPlans(t *testing.T) {
	f := newFixture(t, completeSSE, false)
	b := controlBundle(t, f)
	for _, mode := range []string{"deny", "collision", "clip", "invalid", "policy", "threat", "obligation", "task-type"} {
		t.Run(mode, func(t *testing.T) {
			source := nativeSource(t, f, b, mode)
			artifact := filepath.Join(t.TempDir(), "rejected.json")
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Getenv("WEAVER_CONTROL_SCHEME_COMPILER"), "-e", "(dump-stack-trace? #f)", source)
			cmd.Env = append(os.Environ(), "WEAVER_CONTROL_ARTIFACT="+artifact)
			out, err := cmd.CombinedOutput()
			if err == nil || ctx.Err() != nil {
				t.Fatalf("negative control must reject naturally, not time out: %v %v %s", err, ctx.Err(), out)
			}
			expected := "provider plans must exactly match the native governor handoff"
			if mode == "policy" {
				expected = "Rust rejected inert source Policy/schema"
			}
			if mode == "threat" {
				expected = "native Governance assessment does not admit an inert source handoff"
			}
			if mode == "obligation" {
				expected = "unsupported or invalid Governance source Profile obligations"
			}
			if mode == "task-type" {
				// Container validation reports the enclosing task-list descriptor;
				// Primitive credit contracts are owned by t/gateway-contracts-test.ss.
				expected = "[TypeError]"
			}
			if !strings.Contains(string(out), expected) {
				t.Fatalf("negative control failed for an unrelated reason: %s", out)
			}
			if _, err := os.Stat(artifact); !os.IsNotExist(err) {
				t.Fatal("rejected native governor emitted source artifact")
			}
			if f.primary.Load() != 0 || f.backup.Load() != 0 {
				t.Fatal("governor validation executed provider")
			}
			t.Logf("native governor rejected %s before artifact/publication; observed %q and natural exit", mode, expected)
		})
	}
}
