// Command weaver-dev runs the development gates directly, without a shell.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"

	"github.com/HardenedLinux/weaver/go/internal/devrunner"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() (resultErr error) {
	goBinary := flag.String("go-bin", "", "Go executable; defaults to the compiling toolchain")
	clean := flag.Bool("clean-source", false, "Require every verification input to match the same committed revision")
	schemeSource := flag.String("scheme-source", "", "Agentic AI Lab source checkout for Scheme source qualification")
	schemeLibrary := flag.String("scheme-library", "", "Optional additional qualified Scheme dependency library")
	schemePoo := flag.String("scheme-poo", "", "Gerbil POO checkout at Core's existing declared dependency pin")
	flag.Parse()
	if flag.NArg() != 1 {
		return errors.New("usage: weaver-dev [-go-bin PATH] [-clean-source] bootstrap|bootstrap-build|bootstrap-proofs|check|check-rust|check-go|check-policy|check-architecture|check-scheme|bench|render-diagrams|check-diagrams|generate-rpc|prepare-ci-host")
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
		return devrunner.RenderDiagrams(ctx, working, os.Stdout)
	}
	if flag.Arg(0) == "check-diagrams" {
		return devrunner.CheckDiagrams(ctx, working, os.Stdout)
	}
	if flag.Arg(0) == "scheme-poo-revision" {
		source := *schemeSource
		if !filepath.IsAbs(source) {
			source = filepath.Join(working, source)
		}
		revision, err := devrunner.DeclaredPooRevision(filepath.Join(source, "core"))
		if err != nil {
			return err
		}
		if target := os.Getenv("GITHUB_OUTPUT"); target != "" {
			file, err := os.OpenFile(target, os.O_APPEND|os.O_WRONLY, 0600)
			if err != nil {
				return err
			}
			_, written := fmt.Fprintln(file, "revision="+revision)
			return errors.Join(written, file.Close())
		}
		fmt.Fprintln(os.Stdout, revision)
		return nil
	}
	if flag.Arg(0) == "check-scheme" {
		root, err := devrunner.FindRoot(working)
		if err != nil {
			return err
		}
		settings, err := devrunner.PrepareScheme(ctx, root, *schemeSource, *schemePoo, *schemeLibrary, os.Stdout)
		if err != nil {
			return err
		}
		defer func() { resultErr = errors.Join(resultErr, os.RemoveAll(settings["GERBIL_PATH"])) }()
		for key, value := range settings {
			if err := os.Setenv(key, value); err != nil {
				return err
			}
		}
	}
	_, err = devrunner.Run(ctx, devrunner.Config{Root: working, GoBinary: *goBinary, Mode: flag.Arg(0), RequireClean: *clean}, os.Stdout)
	return err
}
