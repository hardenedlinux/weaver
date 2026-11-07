// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package devrunner

import (
	"io"
	"strings"
	"sync"
	"time"
)

// SchemeTiming observes the SDK's existing output, without changing its entry,
// cleanup or deadline. PreHarness includes discovery/loading; these timestamps
// cannot distinguish boundaries the SDK does not expose.
type SchemeTiming struct {
	PreHarness    string               `json:"preHarness,omitempty"`
	FirstCase     string               `json:"firstCase,omitempty"`
	HarnessDone   string               `json:"harnessDone,omitempty"`
	Terminal      string               `json:"terminal,omitempty"`
	AfterTerminal string               `json:"afterTerminal,omitempty"`
	Archive       []schemeArchiveEvent `json:"archive,omitempty"`
}

type schemeArchiveEvent struct {
	Phase string `json:"phase"`
	State string `json:"state"`
	At    string `json:"at"`
}

type schemeOutput struct {
	mu          sync.Mutex
	destination io.Writer
	started     time.Time
	line        []byte
	observed    SchemeTiming
	terminal    time.Time
}

func (s *schemeOutput) Write(data []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n, err := s.destination.Write(data)
	for _, b := range data[:n] {
		if b == '\n' {
			s.observe(string(s.line), time.Now())
			s.line = s.line[:0]
		} else if len(s.line) < 256 {
			// Only short SDK marker prefixes are needed; never buffer arbitrary
			// provider diagnostics or change the complete log written above.
			s.line = append(s.line, b)
		}
	}
	return n, err
}

func (s *schemeOutput) observe(line string, now time.Time) {
	elapsed := now.Sub(s.started).String()
	switch {
	case strings.HasPrefix(line, "HARNESS ") && s.observed.PreHarness == "":
		s.observed.PreHarness = elapsed
	case strings.HasPrefix(line, "CASE ") && s.observed.FirstCase == "":
		s.observed.FirstCase = elapsed
	case strings.HasPrefix(line, "HARNESS-OK "):
		s.observed.HarnessDone = elapsed
	case line == "OK" && s.terminal.IsZero():
		s.observed.Terminal = elapsed
		s.terminal = now
	case strings.HasPrefix(line, "[weaver-governance "):
		_, event, ok := strings.Cut(line, "] governance-program: phase=")
		phase, state, framed := strings.Cut(event, " state=")
		state, _, _ = strings.Cut(state, " ")
		if ok && framed {
			switch phase {
			case "program-plan", "native-link-inputs", "module-c-batch", "gsc-link", "native-object-batch", "static-archive":
				s.observed.Archive = append(s.observed.Archive, schemeArchiveEvent{Phase: phase, State: state, At: elapsed})
			}
		}
	}
}

func (s *schemeOutput) timing(finished time.Time) *SchemeTiming {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := s.observed
	if !s.terminal.IsZero() {
		result.AfterTerminal = finished.Sub(s.terminal).String()
	}
	return &result
}
