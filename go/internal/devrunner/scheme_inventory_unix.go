//go:build !windows

package devrunner

import (
	"context"
	"os/exec"
	"syscall"
	"time"
)

func runSchemeInventory(parent context.Context, command *exec.Cmd, limit time.Duration) error {
	ctx, cancel := context.WithTimeout(parent, limit)
	defer cancel()
	// Set the deadline on the actual child and its process group. A killed or
	// incomplete child is a failure, never evidence of successful VM cleanup.
	owned := exec.CommandContext(ctx, command.Path, command.Args[1:]...)
	owned.Dir = command.Dir
	owned.Env = command.Env
	owned.Stdout = command.Stdout
	owned.Stderr = command.Stderr
	owned.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	owned.Cancel = func() error { return syscall.Kill(-owned.Process.Pid, syscall.SIGKILL) }
	return owned.Run()
}
