package devrunner

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// Source admission identifies the reviewed backport, independently of whether
// one probabilistic fuzz run happens to encounter the cancellation window.
func TestGoFuzzCoordinatorParentDeadlineAdmission(t *testing.T) {
	source, err := os.ReadFile(filepath.Join(runtime.GOROOT(), "src/internal/fuzz/fuzz.go"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(source, []byte("if err == ctx.Err() || err == fuzzCtx.Err() || isInterruptError(err) {")) {
		t.Fatal("Go fuzz coordinator lacks the upstream parent-deadline fix; use the configured devenv Go package")
	}
}

// A fixed coordinator recognizes its own duration expiry but must still fail a
// real property, including one whose diagnostic mentions the same deadline.
func TestGoFuzzCoordinatorPreservesNativePropertyFailure(t *testing.T) {
	working, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root, err := FindRoot(working)
	if err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{"FuzzNoop", "FuzzPropertyFailure"} {
		t.Run(target, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, filepath.Join(runtime.GOROOT(), "bin/go"), "test",
				"./go/internal/devrunner/testdata/fuzzcontrol", "-run", "^$", "-fuzz", "^"+target+"$", "-fuzztime=3s", "-parallel=1")
			cmd.Dir = root
			output, err := cmd.CombinedOutput()
			if ctx.Err() != nil {
				t.Fatalf("native fuzz control did not finish within its watchdog: %s", output)
			}
			if target == "FuzzNoop" {
				if err != nil {
					t.Fatalf("normal coordinator deadline failed: %v: %s", err, output)
				}
				return
			}
			if err == nil || !bytes.Contains(output, []byte("WeaverNegativeControl: actual property failure: context deadline exceeded")) {
				t.Fatalf("native property failure suppressed or not executed: %v: %s", err, output)
			}
		})
	}
}
