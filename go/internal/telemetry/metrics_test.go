// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

package telemetry

import (
	"google.golang.org/protobuf/reflect/protoreflect"
	"math"
	"sync"
	"testing"
	"testing/quick"
)

func TestPropertyCountersAreBoundedMonotoneAndRestartLocal(t *testing.T) {
	property := func(events []uint8) bool {
		var metrics Metrics
		var expected uint64
		for _, event := range events {
			metrics.Record(Signal(event))
			if Signal(event) == ProviderAdmitted {
				expected++
			}
			if metrics.Snapshot().ProviderAdmitted != expected {
				return false
			}
		}
		var restarted Metrics
		return restarted.Snapshot().ProviderAdmitted == 0
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 1000}); err != nil {
		t.Fatal(err)
	}
}

func TestTelemetryWireExcludesPayloadsAndIdentityLabels(t *testing.T) {
	var metrics Metrics
	fields := metrics.Snapshot().ProtoReflect().Descriptor().Fields()
	for i := 0; i < fields.Len(); i++ {
		field := fields.Get(i)
		if field.Kind() != protoreflect.Uint64Kind || field.IsList() || field.IsMap() {
			t.Fatalf("payload or variable-cardinality field admitted: %s", field.FullName())
		}
	}
}

func TestConcurrentRecordingAndSaturation(t *testing.T) {
	var metrics Metrics
	var workers sync.WaitGroup
	for range 12 {
		workers.Go(func() {
			for range 1000 {
				metrics.Record(ProviderAdmitted)
			}
		})
	}
	workers.Wait()
	if got := metrics.Snapshot().ProviderAdmitted; got != 12000 {
		t.Fatalf("concurrent observations lost: %d", got)
	}
	metrics.counters[ProviderAdmitted].Store(math.MaxUint64)
	metrics.Record(ProviderAdmitted)
	if metrics.Snapshot().ProviderAdmitted != math.MaxUint64 {
		t.Fatal("counter wrapped")
	}
}
