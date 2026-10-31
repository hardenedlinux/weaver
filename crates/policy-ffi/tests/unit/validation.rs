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
