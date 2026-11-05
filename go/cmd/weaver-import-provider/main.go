// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package main

import (
	"errors"
	"fmt"
	"io"
	"os"

	v1 "github.com/HardenedLinux/weaver/go/api/v1"
	"github.com/HardenedLinux/weaver/go/internal/config"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) != 4 || (os.Args[1] != "json" && os.Args[1] != "yaml") {
		return errors.New("usage: weaver-import-provider json|yaml LITELLM_FILE REVIEW_JSON")
	}
	read := func(path string, limit int) ([]byte, error) {
		f, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		defer f.Close()
		return io.ReadAll(io.LimitReader(f, int64(limit)+1))
	}
	source, err := read(os.Args[2], 262144)
	if err != nil {
		return err
	}
	raw, err := read(os.Args[3], v1.MaxInput)
	if err != nil {
		return err
	}
	review, err := v1.Decode[config.ProviderImportReview](raw)
	if err != nil {
		return errors.New("invalid provider review manifest")
	}
	proposal, err := config.ImportProviderCatalog(source, config.ProfileFormat(os.Args[1]), review)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(os.Stdout, string(proposal))
	return err
}
