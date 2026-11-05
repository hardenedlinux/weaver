// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{MAX_SOURCE_BYTES, validate, weaver_policy_abi_v1};

#[test]
fn ffi_preflight_is_bounded_and_rejects_invalid_text() {
    assert_eq!(validate(b"", b"{}"), 2);
    assert_eq!(validate(&[0xff], b"{}"), 2);
    assert_eq!(validate(&vec![b'a'; MAX_SOURCE_BYTES + 1], b"{}"), 2);
    assert_eq!(validate(b"malformed", b"{}"), 1);
    assert_eq!(weaver_policy_abi_v1(), 0x0001_0000);
}

#[test]
fn ffi_preflight_accepts_official_named_json_but_never_duplicate_policy_keys() {
    let policy = include_bytes!("../../../../prod/policies/review/named-permit.json");
    let schema = include_bytes!("../../../../prod/policies/provider/schema.json");
    assert_eq!(validate(policy, schema), 0);
    let source = std::str::from_utf8(policy).expect("JSON");
    let duplicate = source.replacen(
        "\"staticPolicies\":",
        "\"staticPolicies\":{},\"staticPolicies\":",
        1,
    );
    assert_ne!(validate(duplicate.as_bytes(), schema), 0);
}

#[test]
fn aggregate_validity_does_not_establish_complete_source_documents() {
    let schema = include_bytes!("../../../../prod/policies/provider/schema.json");
    let first = b"permit(principal,action,resource)";
    let second = b";";
    assert_eq!(validate(first, schema), 1);
    assert_eq!(validate(second, schema), 1);
    // A single aggregate preflight would accept a statement neither document
    // supplied on its own. Scheme must validate every document before joining.
    assert_eq!(validate(b"permit(principal,action,resource)\n;", schema), 0);
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(128))]
    #[test]
    fn complete_documents_and_composition_share_the_actual_cedar_validator(
        padding in 0usize..128, reverse in proptest::bool::ANY,
        comment in proptest::bool::ANY
    ) {
        let schema = include_bytes!("../../../../prod/policies/provider/schema.json");
        let permit = format!("permit(principal,action,resource);{}{}",
            " ".repeat(padding), if comment { "// trailing comment" } else { "" });
        let forbid = "forbid(principal,action,resource);";
        let documents = if reverse { [forbid, permit.as_str()] } else { [permit.as_str(), forbid] };
        for document in documents {
            proptest::prop_assert_eq!(validate(document.as_bytes(), schema), 0);
        }
        proptest::prop_assert_eq!(validate(documents.join("\n").as_bytes(), schema), 0);
        // Text that actually violates this pinned grammar must stay rejected.
        proptest::prop_assert_eq!(validate(b"permit(principal,action,resource); /*", schema), 1);
    }
}
