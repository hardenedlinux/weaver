// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use crate::OwnedSource;
use crate::source_fixture as fixture;
use proptest::{prop_assert, proptest};
#[test]
fn owned_source_has_no_vm_borrow_and_survives_original_mutation() {
    fn send<T: Send + Sync>() {}
    send::<OwnedSource>();
    let mut original = fixture::source();
    let owned = OwnedSource::from_source(original.clone()).expect("valid source");
    original.tasks[0].family.clear();
    assert_eq!(owned.task().family, "f");
    assert_eq!(owned.plans().len(), 2);
    assert_eq!(owned.publication().operation_id, "source");
}
proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(128))]
    #[test]
    fn original_source_binding_cannot_be_replaced(field in 0usize..6, padding in 1usize..32) {
        let mut data = fixture::source();
        match field {
            0 => data.governance.family = "replacement".into(),
            1 => data.governance.open_nodes = vec!["other".into()],
            2 => data.plans[0].profile_commitment = "0".repeat(64),
            3 => data.plans[0].body.push_str(&" ".repeat(padding)),
            4 => data.plans.push(data.plans[0].clone()),
            _ => data.tasks[0].budget = 0,
        }
        prop_assert!(OwnedSource::from_source(data).is_err());
        prop_assert!(OwnedSource::from_source(fixture::source()).is_ok());
    }
}
