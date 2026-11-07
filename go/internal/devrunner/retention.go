// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
)

const failureTailBytes int64 = 4096

func verificationDirectory(root string) string {
	return filepath.Join(root, ".cache", "verification")
}

func latestResultPath(root, mode string) string {
	if mode == "" {
		mode = "check"
	}
	return filepath.Join(verificationDirectory(root), "latest-"+mode+".json")
}

// summarizeOutput hashes the complete output while retaining at most one bounded
// error tail. Successful output is never copied into the persistent result.
func summarizeOutput(directory string, result *Result) error {
	if result.Log == "" {
		return nil
	}
	if !filepath.IsLocal(result.Log) {
		return errors.New("nonlocal stage output")
	}
	file, err := os.Open(filepath.Join(directory, result.Log))
	if err != nil {
		return err
	}
	defer file.Close()
	digest := sha256.New()
	size, err := io.Copy(digest, file)
	if err != nil {
		return err
	}
	result.OutputSHA256 = hex.EncodeToString(digest.Sum(nil))
	environment := result.Name == "rust-environment" || result.Name == "go-environment" || result.Name == "quint-environment" || result.Name == "proof-environment" || result.Name == "scheme-build-capacity" || result.Name == "grpc-benchmark"
	if result.Status != "PASS" || environment {
		start := max(int64(0), size-failureTailBytes)
		if _, err := file.Seek(start, io.SeekStart); err != nil {
			return err
		}
		tail, err := io.ReadAll(io.LimitReader(file, failureTailBytes))
		if err != nil {
			return err
		}
		if result.Status != "PASS" {
			result.FailureTail = string(tail)
			if _, err := file.Seek(0, io.SeekStart); err != nil {
				return err
			}
			// Preserve the first causal diagnostic as well as the final status.
			// A passing test suffix must not erase an earlier failing case.
			head, err := failureExcerpt(file, slices.Contains(result.Args, "-json"))
			if err != nil {
				return err
			}
			if len(head) > 0 && !bytes.Contains(tail, head) {
				separator := []byte("\n[... final output ...]\n")
				remaining := int(failureTailBytes) - len(head) - len(separator)
				if len(tail) > remaining {
					tail = tail[len(tail)-remaining:]
				}
				result.FailureTail = string(head) + string(separator) + string(tail)
			}
		} else {
			result.Details = string(tail)
		}
	}
	result.Log = ""
	return nil
}

func failureExcerpt(file io.ReadSeeker, goJSON bool) ([]byte, error) {
	if goJSON {
		head, err := firstGoTestFailure(file)
		if err != nil || len(head) != 0 {
			return head, err
		}
		if _, err := file.Seek(0, io.SeekStart); err != nil {
			return nil, err
		}
	}
	return firstFailureExcerpt(file)
}

type goTestEvent struct {
	Action, Test, Output string
}

func firstGoTestFailure(file io.ReadSeeker) ([]byte, error) {
	stream := bufio.NewScanner(file)
	var failed string
	for stream.Scan() {
		var event goTestEvent
		if json.Unmarshal(stream.Bytes(), &event) == nil && event.Action == "fail" && event.Test != "" {
			failed = event.Test
			break
		}
	}
	if failed == "" {
		return nil, stream.Err()
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	const limit = 2048
	header := fmt.Appendf(nil, "Go test failed: %s\n", failed)
	if len(header) >= limit {
		return header[:limit], nil
	}
	available := limit - len(header)
	var output []byte
	stream = bufio.NewScanner(file)
	for stream.Scan() {
		var event goTestEvent
		if json.Unmarshal(stream.Bytes(), &event) != nil || event.Test != failed {
			continue
		}
		if event.Action == "fail" {
			break
		}
		if event.Action == "output" {
			output = append(output, event.Output...)
			if len(output) > available {
				output = append(output[:0], output[len(output)-available:]...)
			}
		}
	}
	return append(header, output...), stream.Err()
}

func firstFailureExcerpt(input io.Reader) ([]byte, error) {
	reader := bufio.NewReaderSize(input, 4096)
	var excerpt, preceding []byte
	for {
		fragment, err := reader.ReadSlice('\n')
		marker := bytes.Contains(fragment, []byte("--- FAIL:")) ||
			bytes.Contains(fragment, []byte("*** ERROR")) ||
			bytes.Contains(fragment, []byte("error:")) ||
			bytes.Contains(fragment, []byte("control readiness:")) ||
			bytes.Contains(fragment, []byte("negative control")) ||
			bytes.HasPrefix(fragment, []byte("panic: test timed out after ")) ||
			bytes.HasPrefix(fragment, []byte("SIGQUIT: quit")) ||
			bytes.Contains(fragment, []byte(`"Output":"panic: test timed out after `)) ||
			bytes.Contains(fragment, []byte(`"Output":"SIGQUIT: quit`))
		if len(excerpt) == 0 && marker {
			// Go prints t.Fatal diagnostics before the FAIL marker. Keep a
			// bounded preceding window rather than retaining only later passes.
			excerpt = append(excerpt, preceding...)
		}
		if len(excerpt) > 0 || marker {
			n := min(len(fragment), 2048-len(excerpt))
			excerpt = append(excerpt, fragment[:n]...)
			if len(excerpt) == 2048 {
				return excerpt, nil
			}
		} else {
			preceding = append(preceding, fragment...)
			if len(preceding) > 1024 {
				preceding = append(preceding[:0], preceding[len(preceding)-1024:]...)
			}
		}
		if errors.Is(err, io.EOF) {
			return excerpt, nil
		}
		if err != nil && !errors.Is(err, bufio.ErrBufferFull) {
			return nil, err
		}
	}
}

func publishLatestResult(root, directory, mode string, runErr error) (path string, err error) {
	defer func() { err = errors.Join(err, os.RemoveAll(directory)) }()
	if mode == "" {
		mode = "check"
	}
	if _, invalid := Stages(mode, "go"); invalid != nil {
		return "", invalid
	}
	path = latestResultPath(root, mode)
	var receipt Receipt
	bytes, readErr := os.ReadFile(filepath.Join(directory, "receipt.json"))
	if readErr == nil {
		readErr = json.Unmarshal(bytes, &receipt)
	}
	if readErr != nil {
		receipt = Receipt{Status: "FAIL", Root: root, Mode: mode}
		receipt.Stages = []Result{{Name: "initialization", Status: "FAIL", Error: fmt.Sprint(errors.Join(runErr, readErr))}}
		err = errors.Join(err, readErr)
	}
	if runErr != nil {
		if receipt.Status == "PASS" {
			receipt.Stages = append(receipt.Stages, Result{Name: "run-finalization", Status: "FAIL", Error: runErr.Error()})
		}
		if receipt.Status != "CANCELLED" && receipt.Status != "TIMEOUT" {
			receipt.Status = "FAIL"
		}
	}
	for index := range receipt.Stages {
		if failure := summarizeOutput(directory, &receipt.Stages[index]); failure != nil {
			err = errors.Join(err, failure)
		}
		receipt.Stages[index].Log = ""
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return path, err
	}
	if mode == "bench" && receipt.Status == "PASS" {
		if summary, failure := os.ReadFile(filepath.Join(directory, "benchmark-summary.org")); failure == nil {
			if err := os.WriteFile(filepath.Join(filepath.Dir(path), "latest-benchmark-summary.org"), summary, 0600); err != nil {
				return path, err
			}
		} else {
			err = errors.Join(err, failure)
		}
	}
	err = errors.Join(err, os.RemoveAll(directory))
	if err != nil {
		receipt.Status = "FAIL"
		receipt.Stages = append(receipt.Stages, Result{Name: "result-cleanup", Status: "FAIL", Error: err.Error()})
	}
	encoded, marshalErr := json.MarshalIndent(receipt, "", "  ")
	if marshalErr != nil {
		return path, errors.Join(err, marshalErr)
	}
	pending, failure := os.CreateTemp(filepath.Dir(path), ".latest-"+mode+"-*")
	if failure != nil {
		return path, errors.Join(err, failure)
	}
	defer os.Remove(pending.Name())
	_, written := pending.Write(append(encoded, '\n'))
	closed := pending.Close()
	if failure := errors.Join(written, closed); failure != nil {
		return path, errors.Join(err, failure)
	}
	if failure := os.Rename(pending.Name(), path); failure != nil {
		return path, errors.Join(err, failure)
	}
	return path, err
}
