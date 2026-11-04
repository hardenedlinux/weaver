// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::fixtures::{initialized, proposal};
use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config as ProptestConfig};
use std::collections::{BTreeMap, BTreeSet};
use weaver_contracts::Outcome;
use weaver_ledger::Ledger;

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]
    #[test]
    fn arbitrary_replays_restarts_and_consumption_preserve_claims(events in proptest::collection::vec((0u8..8,1u64..12,0u8..4),1..35)) {
        let temp=tempfile::tempdir().expect("temp");let path=temp.path().join("ledger.db");
        let mut ledger=initialized(&path);
        // Independent oracle: original per-key allocation and irreversible spent set.
        let mut holds=BTreeMap::<u8,u64>::new();let mut spent=BTreeSet::new();let mut calls=BTreeSet::new();
        for (node,ceiling,action) in events {
            match action {
                0|1 => {
                    let expected=holds.get(&node).map_or(holds.values().sum::<u64>()+ceiling<=20,|old| *old==ceiling);
                    let actual=ledger.enqueue(&proposal(node,ceiling));prop_assert_eq!(actual.is_ok(),expected);
                    if expected { holds.entry(node).or_insert(ceiling); }
                }
                2 => {
                    let expected=holds.contains_key(&node) && !spent.contains(&node);
                    let actual=ledger.consume("family",&format!("n{node}"));prop_assert_eq!(actual.is_ok(),expected);
                    if let Ok(permit)=actual {
                        spent.insert(node);
                        ledger.dispatch(permit, |_| {assert!(calls.insert(node));}).expect("dispatch");
                    }
                }
                _ => {drop(ledger);ledger=Ledger::open(&path).expect("reopen");}
            }
            prop_assert_eq!(ledger.held("family").expect("held"),holds.values().sum::<u64>());
            prop_assert!(holds.values().sum::<u64>()<=20);
            for &node in &spent {prop_assert_eq!(ledger.lookup("family",&format!("n{node}")).expect("lookup").expect("receipt").outcome,Outcome::Unknown);}
        }
    }
}
