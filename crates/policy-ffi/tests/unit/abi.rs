use crate::{MAX_SOURCE_BYTES, weaver_policy_validate_v1};

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
