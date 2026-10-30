// Command weaver-control serves authenticated routing over gRPC to the Rust broker.
package main

import (
	"context"
	"fmt"
	"github.com/HardenedLinux/weaver/go/internal/controlplane"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := controlplane.RunFromEnv(ctx); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
