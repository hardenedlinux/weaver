// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//go:build !unix

package devrunner

import (
	"os/exec"
	"time"
)

func boundStageProcess(cmd *exec.Cmd) {
	cmd.WaitDelay = 2 * time.Second
}
