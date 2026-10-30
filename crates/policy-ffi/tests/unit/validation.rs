use crate::{MAX_SOURCE_BYTES, validate, weaver_policy_abi_v1};

#[test]
fn ffi_preflight_is_bounded_and_rejects_invalid_text() {
    assert_eq!(validate(b"", b"{}"), 2);
    assert_eq!(validate(&[0xff], b"{}"), 2);
    assert_eq!(validate(&vec![b'a'; MAX_SOURCE_BYTES + 1], b"{}"), 2);
    assert_eq!(validate(b"malformed", b"{}"), 1);
    assert_eq!(weaver_policy_abi_v1(), 0x0001_0000);
}
