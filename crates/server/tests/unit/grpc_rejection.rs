// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::rejection_reason;
use weaver_contracts::Error;

#[test]
fn rejection_reasons_keep_static_causes_and_exclude_dynamic_data() {
    assert_eq!(
        rejection_reason(&Error::Conflict("delivery cancelled or expired")),
        "delivery cancelled or expired",
    );
    let dynamic = "private source and request contents";
    for error in [
        Error::Storage(dynamic.into()),
        Error::Policy(dynamic.into()),
    ] {
        assert_eq!(rejection_reason(&error), "native validation failed");
    }
}
