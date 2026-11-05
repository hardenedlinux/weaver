// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded, inert Cedar source validation shared by the safe and C ABI entries.
/// Maximum borrowed UTF-8 source length for each Policy C ABI input.
pub const MAX_SOURCE_BYTES: usize = 65_536;

/// Safe shared implementation; final Rust publication repeats the same check.
pub fn validate(policy: &[u8], schema: &[u8]) -> i32 {
    if policy.is_empty()
        || schema.is_empty()
        || policy.len() > MAX_SOURCE_BYTES
        || schema.len() > MAX_SOURCE_BYTES
    {
        return 2;
    }
    let (Ok(policy), Ok(schema)) = (std::str::from_utf8(policy), std::str::from_utf8(schema))
    else {
        return 2;
    };
    match std::panic::catch_unwind(|| weaver_policy::validate_typed(policy, schema)) {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => 1,
        Err(_) => 3,
    }
}
