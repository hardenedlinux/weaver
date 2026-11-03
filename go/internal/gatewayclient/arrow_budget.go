// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

package gatewayclient

import "github.com/apache/arrow-go/v18/arrow/memory"

// IPC buffer allocations are charged cumulatively, including replacement buffers.
// Free never restores a message's allowance. Each Events call gets a fresh budget.
// This bounds allocations through Arrow's allocator, not codec/runtime heap usage.
const arrowBufferBudget = 8 << 20
const arrowTextBudget = 4 << 20

type arrowAllocationLimit struct{}

func (arrowAllocationLimit) Error() string { return "Arrow buffer allocation budget exceeded" }

type arrowAllocator struct {
	base  memory.Allocator
	used  int
	limit int
}

func (a *arrowAllocator) charge(size int) {
	if size < 0 || size > a.limit-a.used {
		// Arrow's Allocator has no error return. Its synchronous IPC reader
		// catches allocation panics and reports a failed read to Events.
		panic(arrowAllocationLimit{})
	}
	a.used += size
}

func (a *arrowAllocator) Allocate(size int) []byte {
	a.charge(size)
	return a.base.Allocate(size)
}

func (a *arrowAllocator) Reallocate(size int, old []byte) []byte {
	a.charge(size)
	if size == 0 {
		a.base.Free(old)
		return nil
	}
	if len(old) == 0 {
		return a.base.Allocate(size)
	}
	return a.base.Reallocate(size, old)
}

func (a *arrowAllocator) Free(buffer []byte) { a.base.Free(buffer) }
