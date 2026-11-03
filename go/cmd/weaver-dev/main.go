// Command weaver-dev runs the development gates directly, without a shell.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"

	"github.com/HardenedLinux/weaver/go/internal/devrunner"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	goBinary := flag.String("go-bin", "", "Go executable; defaults to the compiling toolchain")
	clean := flag.Bool("clean-source", false, "Require every verification input to match the same committed revision")
	view := flag.String("view", "", "Render one exact SysML-mapped D2 source; default renders the complete inventory")
	flag.Parse()
	if flag.NArg() != 1 {
		return errors.New("usage: weaver-dev [-go-bin PATH] [-clean-source] bootstrap|bootstrap-build|bootstrap-proofs|check|check-rust|check-go|check-policy|check-architecture|check-scheme|check-storage|check-telemetry|bench|bench-runtime|render-diagrams|check-diagrams|generate-rpc|prepare-ci-host")
	}
	if flag.Arg(0) == "prepare-ci-host" {
		return devrunner.PrepareHostedCI(os.Stdout)
	}
	if flag.Arg(0) == "prepare-ci-tools" {
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
		defer stop()
		return devrunner.PrepareCITools(ctx, os.Stdout)
	}
	working, err := os.Getwd()
	if err != nil {
		return err
	}
	working, err = devrunner.FindRoot(working)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if flag.Arg(0) == "render-diagrams" {
		if *view != "" {
			return devrunner.RenderDiagrams(ctx, working, os.Stdout, *view)
		}
		return devrunner.RenderDiagrams(ctx, working, os.Stdout)
	}
	if flag.Arg(0) == "check-diagrams" {
		if *view != "" {
			return devrunner.CheckDiagrams(ctx, working, os.Stdout, *view)
		}
		return devrunner.CheckDiagrams(ctx, working, os.Stdout)
	}
	if *view != "" {
		return errors.New("-view requires render-diagrams or check-diagrams")
	}
	_, err = devrunner.Run(ctx, devrunner.Config{Root: working, GoBinary: *goBinary, Mode: flag.Arg(0), RequireClean: *clean}, os.Stdout)
	return err
}
