package controlplane

import (
	"context"
	"errors"
	"github.com/HardenedLinux/weaver/go/internal/config"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Scheme is trusted source compilation before publication, never agent request IPC.
// A partial artifact or failed/nonterminating compiler cannot activate the service.
func compileScheme(ctx context.Context, path string) (config.Bundle, error) {
	var zero config.Bundle
	compiler, err := required("WEAVER_CONTROL_SCHEME_COMPILER")
	if err != nil {
		return zero, err
	}
	if !filepath.IsAbs(compiler) {
		return zero, errors.New("explicit absolute Scheme compiler required")
	}
	directory, err := os.MkdirTemp("", "weaver-source-*")
	if err != nil {
		return zero, err
	}
	defer os.RemoveAll(directory)
	artifact := filepath.Join(directory, "bundle.json")
	source, err := filepath.Abs(path)
	if err != nil {
		return zero, err
	}
	// A rejected configuration must not spend its startup budget pretty-printing
	// a continuation containing the complete Yuanxu module graph. Exceptions,
	// nonzero natural exit, validation and resource cleanup remain unchanged.
	cmd := exec.CommandContext(ctx, compiler, "-e", "(dump-stack-trace? #f)", source)
	cmd.Dir = filepath.Dir(source)
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "WEAVER_CONTROL_ARTIFACT=") {
			cmd.Env = append(cmd.Env, entry)
		}
	}
	cmd.Env = append(cmd.Env, "WEAVER_CONTROL_ARTIFACT="+artifact)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	started := time.Now()
	if err = cmd.Start(); err != nil {
		return zero, err
	}
	// Log only process/phase metadata, never source paths, content or credentials.
	// A started child, written artifact or zero exit alone cannot activate ingress.
	slog.InfoContext(ctx, "Scheme source process", "phase", "started", "pid", cmd.Process.Pid, "unix_us", started.UnixMicro())
	err = cmd.Wait()
	slog.InfoContext(ctx, "Scheme source process", "phase", "reaped", "pid", cmd.Process.Pid,
		"unix_us", time.Now().UnixMicro(), "elapsed", time.Since(started), "success", err == nil, "canceled", ctx.Err() != nil)
	if err != nil {
		return zero, err
	}
	file, err := os.Open(artifact)
	if err != nil {
		return zero, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, (8<<20)+1))
	if err != nil {
		return zero, err
	}
	bundle, err := config.DecodeBundle(data, config.ProfileJSON)
	slog.InfoContext(ctx, "Scheme source artifact", "phase", "decoded", "bytes", len(data), "success", err == nil)
	return bundle, err
}
