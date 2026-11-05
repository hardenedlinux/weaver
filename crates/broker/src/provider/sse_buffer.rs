// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

/// A lookahead read may consume only complete records already in the decoder buffer.
pub(super) fn buffered_sse_record(bytes: &[u8]) -> bool {
    bytes
        .split_inclusive(|byte| *byte == b'\n')
        .any(|line| matches!(line, b"\n" | b"\r\n"))
}
