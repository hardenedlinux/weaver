package devrunner

import (
	"bufio"
	"errors"
	"os"
	"strings"
)

// The pinned SDK CLI may return zero even when its test main returns 42.
// Keep the original nineteen-case gate as well as the SDK's terminal result;
// a process exit, import failure or empty harness cannot qualify the package.
func validateSchemeResult(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	cases, harness, last := 0, false, ""
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "CASE-OK ") {
			cases++
		}
		if strings.HasPrefix(line, "HARNESS-OK ") {
			harness = true
		}
		if strings.Contains(line, "*** ERROR") || strings.HasPrefix(line, "CASE-FAIL") || strings.HasPrefix(line, "HARNESS-ERROR") {
			return errors.New("Scheme package test diagnostics report failure")
		}
		if strings.TrimSpace(line) != "" {
			last = strings.TrimSpace(line)
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if cases != 19 || !harness || last != "OK" {
		return errors.New("Scheme package test result is incomplete")
	}
	return nil
}
