// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//go:build integration && !windows

package dev

import "testing"

// Reuse the actual mTLS/gRPC/provider fault tests against the explicit MVCC service.
func TestProviderMVCCExecutionBoundary(t *testing.T) {
	t.Setenv("WEAVER_STORAGE_JOURNAL", "mvcc")
	for _, test := range []struct {
		name string
		run  func(*testing.T)
	}{
		{"duplicates", TestProviderConcurrentRPCDuplicatesInvokeOnce},
		{"header-wait", TestProviderHeaderWaitAuthorityBoundary},
		{"early-headers", TestProviderEarlyHeadersAndPartialBody},
		{"revocation", TestProviderRevocationDuringSSEStopsNextRelease},
		{"partial-restart", TestProviderPartialRequestAndRestartRetainUnknownClaim},
		{"reply-loss", TestProviderPublicationLostReplyRestartAndHistoricalDecision},
		{"retry-fallback", TestProviderFailuresNeverRetryOrFallback},
		{"stream-retry", TestProviderClientCancellationCannotReplay},
	} {
		t.Run(test.name, test.run)
	}
}
