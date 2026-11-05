// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Reviewed ABI leaf. A valid bounded borrowed region is the C caller's premise.
use crate::MAX_SOURCE_BYTES;

/// Report the stable local Policy preflight ABI identifier.
#[unsafe(no_mangle)]
pub extern "C" fn weaver_policy_abi_v1() -> u32 {
    0x0001_0000
}

/// Validate an inert Policy/schema pair. Status 0 is not an execution permit.
///
/// # Safety
/// For each non-null pointer, the caller must supply a readable region of its
/// stated length, alive and immutable until return. Regions may overlap.
/// Rust borrows synchronously and retains no pointer. Invalid addresses cannot
/// be made safe by length checks or panic containment; they violate this ABI.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn weaver_policy_validate_v1(
    policy: *const u8,
    policy_len: usize,
    schema: *const u8,
    schema_len: usize,
) -> i32 {
    if policy.is_null()
        || schema.is_null()
        || policy_len == 0
        || schema_len == 0
        || policy_len > MAX_SOURCE_BYTES
        || schema_len > MAX_SOURCE_BYTES
    {
        return 2;
    }
    // SAFETY: the checked bounds and documented caller region/lifetime premise
    // establish two shared byte slices; no reference escapes this call.
    let (policy, schema) = unsafe {
        (
            std::slice::from_raw_parts(policy, policy_len),
            std::slice::from_raw_parts(schema, schema_len),
        )
    };
    crate::validate(policy, schema)
}

#[cfg(test)]
#[path = "../tests/unit/abi.rs"]
mod tests;
