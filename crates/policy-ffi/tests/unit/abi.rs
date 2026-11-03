// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use crate::{MAX_SOURCE_BYTES, weaver_policy_validate_v1};
use proptest::{prop_assert_eq, proptest};

#[test]
fn bad_regions_are_rejected_before_dereference() {
    // SAFETY: null pointers are rejected without constructing a slice.
    let null = unsafe { weaver_policy_validate_v1(std::ptr::null(), 1, std::ptr::null(), 1) };
    assert_eq!(null, 2);
    let data = b"{}";
    // SAFETY: an oversized length is rejected before either region is read.
    let oversized =
        unsafe { weaver_policy_validate_v1(data.as_ptr(), MAX_SOURCE_BYTES + 1, data.as_ptr(), 2) };
    assert_eq!(oversized, 2);
}

proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(128))]
    #[test]
    fn unicode_byte_limits_apply_to_each_actual_abi_region(
        scalar in 0usize..4, adjustment in -1i32..2, oversized_schema in proptest::bool::ANY
    ) {
        let character = ['a', 'é', '中', '🦀'][scalar];
        let statement = "forbid(principal,action,resource);";
        let overhead = statement.len() + 3; // Two comment slashes and its newline.
        let fit = (MAX_SOURCE_BYTES - overhead) / character.len_utf8();
        let count = fit.checked_add_signed(adjustment as isize).expect("positive bounded count");
        let policy = format!("//{}\n{statement}", character.to_string().repeat(count));
        let mut schema = include_str!("../../../../prod/policies/provider/schema.json").to_owned();
        if oversized_schema {
            schema.push_str(&" ".repeat(MAX_SOURCE_BYTES + 1 - schema.len()));
        }
        let expected = if policy.len() > MAX_SOURCE_BYTES || oversized_schema { 2 } else { 0 };
        // SAFETY: both regions are actual immutable owned UTF-8 buffers, alive
        // throughout this synchronous call. No fabricated address is exercised.
        let observed = unsafe {
            weaver_policy_validate_v1(policy.as_ptr(), policy.len(), schema.as_ptr(), schema.len())
        };
        prop_assert_eq!(observed, expected);
    }
}
