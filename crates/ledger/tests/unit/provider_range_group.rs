// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{SCHEMA, fixture};
use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use std::collections::BTreeSet;
use weaver_ledger::{Ledger, persistence};

proptest! {
    #![proptest_config(Config::with_cases(20))]

    #[test]
    fn grouped_preparation_rolls_back_a_partial_insert_and_preserves_unknown_hold(
        first in 1u64..=16, second in 1u64..=16, revoke in proptest::bool::ANY,
    ) {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("group.db");
        let storage = persistence::Session::open_with_journal(&path, persistence::Journal::Mvcc)
            .expect("native MVCC observer");
        let (mut ledger, plan) = fixture(&path);
        ledger.enqueue_provider(&plan).expect("reserve original");
        let targets = BTreeSet::from(["primary".into()]);
        let owner = ledger.consume_provider("f", "infer", &targets).expect("consume original");
        ledger.dispatch_provider(&owner, || Ok(())).expect("burn request");
        // Force the second native insert to collide after the first was staged.
        persistence::exec(&storage,
            "INSERT INTO provider_releases VALUES('f','infer',?1,1,'test-cut','released')", [first as i64])
            .expect("inject partial insertion collision");
        prop_assert!(ledger.prepare_provider_releases(&owner, &[("over", 32), ("limit", 1)], "arrow").is_err());
        let ranges = [("first", first), ("second", second)];
        prop_assert!(ledger.prepare_provider_releases(&owner, &ranges, "arrow").is_err());
        let prefix: i64 = persistence::one(&storage,
            "SELECT COUNT(*) FROM provider_releases WHERE sequence=0", (), |row| row.get(0))
            .expect("independent rollback observation");
        prop_assert_eq!(prefix, 0);
        prop_assert_eq!(ledger.provider_receipt("f","infer").expect("inspect").expect("original").events, 0);
        persistence::exec(&storage, "DELETE FROM provider_releases WHERE digest='test-cut'", ())
            .expect("remove injected collision");
        let mut group = ledger.prepare_provider_releases(&owner, &ranges, "arrow").expect("group");
        let tail = group.pop().expect("tail");
        prop_assert_eq!(tail.first_sequence(), first);
        if revoke {
            let prefix = group.pop().expect("prefix");
            ledger.release_provider(&owner, prefix, "arrow", |_| Ok(())).expect("emit authorized prefix");
            ledger.publish_typed(Some(0), "forbid(principal,action,resource);", SCHEMA, 2)
                .expect("new fence");
        }
        let mut calls = 0;
        let tail_result = ledger.release_provider(&owner, tail, "arrow", |_| {
            calls += 1;
            Ok(())
        });
        prop_assert!(tail_result.is_err());
        prop_assert_eq!(calls, 0);
        ledger.close().expect("close old worker");
        let mut recovered = Ledger::open(&path).expect("recover original");
        prop_assert!(recovered.consume_provider("f", "infer", &targets).is_err());
        let original = recovered.provider_receipt("f","infer").expect("inspect").expect("original");
        prop_assert_eq!((original.events, original.held), (first + second, 4));
        prop_assert_eq!(original.state, weaver_contracts::ProviderState::Unknown);
    }
}
