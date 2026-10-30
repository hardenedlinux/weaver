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
	clean := flag.Bool("clean-source", false, "Require every verification input to match the same committed revision")
	schemeSource := flag.String("scheme-source", "", "Agentic AI Lab source checkout for native Scheme qualification")
	schemeLibrary := flag.String("scheme-library", "", "Qualified native Scheme dependency library")
	schemePoo := flag.String("scheme-poo", "", "Gerbil POO checkout at Core's existing declared dependency pin")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: weaver-dev [-go-bin PATH] [-clean-source] bootstrap|check|bench|generate-rpc|prepare-ci-host")
		os.Exit(2)
	}
	if flag.Arg(0) == "prepare-ci-host" {
		if err := devrunner.PrepareHostedCI(os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	working, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if flag.Arg(0) == "check-scheme" {
		root, err := devrunner.FindRoot(working)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		settings, err := devrunner.PrepareScheme(ctx, root, *schemeSource, *schemePoo, *schemeLibrary, os.Stdout)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		for key, value := range settings {
			if err := os.Setenv(key, value); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
	}
	_, err = devrunner.Run(ctx, devrunner.Config{Root: working, GoBinary: *goBinary, Mode: flag.Arg(0), RequireClean: *clean}, os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
