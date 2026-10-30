//go:build windows

package devrunner

import (
	"context"
	"errors"
	"os/exec"
	"time"
)

func runSchemeInventory(context.Context, *exec.Cmd, time.Duration) error {
	return errors.New("Darwin module packaging is unavailable on Windows")
}
