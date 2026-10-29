// Command weaver-dev runs the development gates directly, without a shell.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"

	"github.com/HardenedLinux/weaver/go/internal/devrunner"
)

func main() {
	goBinary := flag.String("go-bin", "", "Go executable; defaults to the compiling toolchain")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: weaver-dev [-go-bin PATH] check|bench|generate-rpc")
		os.Exit(2)
	}
	working, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	_, err = devrunner.Run(ctx, devrunner.Config{Root: working, GoBinary: *goBinary, Mode: flag.Arg(0)}, os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
