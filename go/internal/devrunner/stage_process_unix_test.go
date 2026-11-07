// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build unix

package devrunner

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestStageDeadlineRetainsEvidenceAndStopsChild(t *testing.T) {
	root, scratch := t.TempDir(), t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	result := runStage(ctx, root, scratch, os.Environ(), Stage{
		Name: "deadline-control", Binary: "sh",
		Args: []string{"-c", "(sleep 1; touch survived) & echo child-started; wait"},
	})
	if result.Status != "TIMEOUT" || !strings.Contains(result.Error, context.DeadlineExceeded.Error()) {
		t.Fatalf("expected a timeout result, got %+v", result)
	}
	receipt := Receipt{Status: "TIMEOUT", Root: root, Mode: "check", Stages: []Result{result}}
	if err := writeReceipt(scratch, receipt); err != nil {
		t.Fatal(err)
	}
	path, err := publishLatestResult(root, scratch, "check", context.DeadlineExceeded)
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(content), "child-started") || !strings.Contains(string(content), `"status": "TIMEOUT"`) {
		t.Fatalf("timeout evidence was lost: %s (%v)", content, err)
	}
	time.Sleep(1100 * time.Millisecond)
	if _, err := os.Stat(filepath.Join(root, "survived")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("descendant escaped stage cancellation: %v", err)
	}
}
