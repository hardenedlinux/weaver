// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package devrunner

import (
	"bufio"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Match an unfiltered standard Gerbil test directory. The SDK's
// collect-files selects direct -test.ss entries in this directory; no separate
// module manifest or frozen case count is maintained here.
func schemeTestModules(root, directory string) ([]string, error) {
	if !filepath.IsLocal(directory) {
		return nil, errors.New("Scheme test directory must be local")
	}
	entries, err := os.ReadDir(filepath.Join(root, directory))
	if err != nil {
		return nil, err
	}
	var modules []string
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), "-test.ss") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() {
			return nil, errors.New("Scheme test inventory requires regular source files")
		}
		modules = append(modules, filepath.ToSlash(filepath.Join(directory, entry.Name())))
	}
	if len(modules) == 0 {
		return nil, errors.New("Scheme test inventory is empty")
	}
	return modules, nil
}

type schemeTestFrame struct {
	kind, name string
}

// The SDK CLI may return zero even when its test main returns 42. Require the
// actual source module inventory, balanced suite/case results and terminal OK.
// The caller separately owns process exit, deadline and source-currentness.
func validateSchemeResult(root, directory, path string) error {
	modules, err := schemeTestModules(root, directory)
	if err != nil {
		return err
	}
	expected, quoted := make(map[string]bool, len(modules)), make([]string, len(modules))
	for index, module := range modules {
		expected[module], quoted[index] = true, strconv.Quote(module)
	}
	description := "(" + strings.Join(quoted, " ") + ")"
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	started, completed, last := false, false, ""
	seen := make(map[string]bool, len(modules))
	active, cases := "", 0
	var frames []schemeTestFrame
	incomplete := errors.New("Scheme package test result is incomplete or inconsistent")
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, "*** ERROR") || strings.HasPrefix(line, "CASE-FAIL") || strings.HasPrefix(line, "CASE-ERROR") || strings.HasPrefix(line, "SUITE-FAIL") || strings.HasPrefix(line, "SUITE-ERROR") || strings.HasPrefix(line, "MODULE-FAIL") || strings.HasPrefix(line, "MODULE-ERROR") || strings.HasPrefix(line, "HARNESS-FAIL") || strings.HasPrefix(line, "HARNESS-ERROR") {
			return errors.New("Scheme package test diagnostics report failure")
		}
		switch {
		case strings.HasPrefix(line, "HARNESS "):
			if started || strings.TrimPrefix(line, "HARNESS ") != description {
				return incomplete
			}
			started = true
		case strings.HasPrefix(line, "MODULE "):
			name := strings.TrimPrefix(line, "MODULE ")
			if !started || completed || active != "" || !expected[name] || seen[name] {
				return incomplete
			}
			active, cases, seen[name] = name, 0, true
		case strings.HasPrefix(line, "CASE "), strings.HasPrefix(line, "SUITE "):
			if active == "" || completed {
				return incomplete
			}
			kind, name, _ := strings.Cut(line, " ")
			frames = append(frames, schemeTestFrame{kind: kind, name: name})
		case strings.HasPrefix(line, "CASE-OK "), strings.HasPrefix(line, "SUITE-OK "):
			kind, name, _ := strings.Cut(line, "-OK ")
			if len(frames) == 0 || frames[len(frames)-1] != (schemeTestFrame{kind: kind, name: name}) {
				return incomplete
			}
			frames = frames[:len(frames)-1]
			if kind == "CASE" {
				cases++
			}
		case strings.HasPrefix(line, "MODULE-OK "):
			if active == "" || strings.TrimPrefix(line, "MODULE-OK ") != active || len(frames) != 0 || cases == 0 {
				return incomplete
			}
			active = ""
		case strings.HasPrefix(line, "HARNESS-OK "):
			if !started || completed || active != "" || len(seen) != len(expected) || strings.TrimPrefix(line, "HARNESS-OK ") != description {
				return incomplete
			}
			completed = true
		}
		if strings.TrimSpace(line) != "" {
			last = strings.TrimSpace(line)
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if !completed || last != "OK" {
		return incomplete
	}
	return nil
}
