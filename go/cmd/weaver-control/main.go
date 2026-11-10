// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Command weaver-control prepares source state; serve retains the reference relay.
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
	action := controlplane.PrepareFromEnv
	if len(os.Args) > 2 || (len(os.Args) == 2 && os.Args[1] != "prepare" && os.Args[1] != "serve") {
		fmt.Fprintln(os.Stderr, "usage: weaver-control [prepare|serve]")
		os.Exit(2)
	}
	if len(os.Args) == 2 && os.Args[1] == "serve" {
		action = controlplane.RunFromEnv
	}
	if err := action(ctx); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
