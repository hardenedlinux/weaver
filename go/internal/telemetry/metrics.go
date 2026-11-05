// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

// Package telemetry records fixed-cardinality, process-local observations only.
// It accepts no payloads, labels, trace context, credentials or export callbacks.
package telemetry

import (
	pb "github.com/HardenedLinux/weaver/go/api/gateway/v1"
	"math"
	"sync/atomic"
)

type Signal uint8

const (
	CompilationSucceeded Signal = iota
	CompilationFailed
	ProviderAdmitted
	ProviderCompleted
	ProviderFailed
	ResponseFramesQueued
	QueueWaitFailed
	RPCAuthRejected
	SnapshotReads
	signalCount
)

// Metrics needs no worker or exporter. A zero value is immediately usable.
type Metrics struct{ counters [signalCount]atomic.Uint64 }

func (m *Metrics) Record(signal Signal) {
	if signal >= signalCount {
		return
	}
	counter := &m.counters[signal]
	for n := counter.Load(); n != math.MaxUint64; n = counter.Load() {
		if counter.CompareAndSwap(n, n+1) {
			return
		}
	}
}

// Snapshot reads independent atomic values; it is not a coherent authority cut.
// Restart resets counters. Neither a count nor zero is durable execution evidence.
func (m *Metrics) Snapshot() *pb.TelemetrySnapshot {
	return &pb.TelemetrySnapshot{
		CompilationsSucceeded: m.counters[CompilationSucceeded].Load(),
		CompilationsFailed:    m.counters[CompilationFailed].Load(),
		ProviderAdmitted:      m.counters[ProviderAdmitted].Load(),
		ProviderCompleted:     m.counters[ProviderCompleted].Load(),
		ProviderFailed:        m.counters[ProviderFailed].Load(),
		ResponseFramesQueued:  m.counters[ResponseFramesQueued].Load(),
		QueueWaitFailed:       m.counters[QueueWaitFailed].Load(),
		RpcAuthRejected:       m.counters[RPCAuthRejected].Load(),
		SnapshotReads:         m.counters[SnapshotReads].Load(),
	}
}
