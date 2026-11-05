// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::Roots;
use proptest::{prop_assert, proptest};

proptest! {
    #[test]
    fn shared_quota_roots_cannot_be_partitioned_by_family(tenant in 0u16..1000, dimension in 0usize..3) {
        let mut left = Roots { execution: ["a".into(),"a".into(),"a".into()], quota: Some(["ka".into(),"ua".into(),"ta".into()]) };
        let mut right = Roots { execution: ["b".into(),"b".into(),"b".into()], quota: Some(["kb".into(),"ub".into(),"tb".into()]) };
        prop_assert!(!left.overlaps(&right));
        let shared = format!("root-{tenant}");
        left.quota.as_mut().expect("left")[dimension] = shared.clone();
        right.quota.as_mut().expect("right")[dimension] = shared;
        prop_assert!(left.overlaps(&right));
    }
}
