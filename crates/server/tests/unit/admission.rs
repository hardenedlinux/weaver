// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::Admission;
use crate::runtime::RuntimeOwner;
use std::{sync::Arc, time::Duration};
use tokio::sync::oneshot;

#[tokio::test]
async fn saturated_detached_execution_preserves_publication_and_observation_custody() {
    let lanes = Admission::new(1);
    let owner = RuntimeOwner::new();
    let (entered, started) = oneshot::channel();
    let (release, blocked) = std::sync::mpsc::channel();
    let job = owner
        .spawn_blocking(lanes.execution().expect("execute"), move |_| {
            let _ = entered.send(());
            blocked
                .recv_timeout(Duration::from_secs(3))
                .expect("release worker");
            Ok(())
        })
        .expect("tracked");
    started.await.expect("started");
    drop(job);
    assert!(
        lanes.execution().is_err(),
        "disconnect must not return native capacity"
    );
    let publication = lanes.publication().expect("reserved publication");
    assert!(lanes.publication().is_err(), "publication is bounded");
    let first = lanes.observation().expect("first observation");
    let second = lanes.observation().expect("second observation");
    assert!(lanes.observation().is_err(), "observation is bounded");
    let copied = Arc::clone(&publication);
    drop(publication);
    assert!(
        lanes.publication().is_err(),
        "last native custodian owns the slot"
    );
    drop(copied);
    drop((first, second));
    assert!(lanes.publication().is_ok());
    release.send(()).expect("release");
    tokio::time::timeout(Duration::from_secs(3), owner.drain())
        .await
        .expect("drain");
    assert!(lanes.execution().is_ok());
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(64))]
    #[test]
    fn lane_interleavings_preserve_independent_bounds(
        actions in proptest::collection::vec(0u8..6, 1..128), execution in 1usize..=32
    ) {
        let lanes = Admission::new(execution);
        let limits = [execution, 1, 2];
        let mut held = [Vec::new(), Vec::new(), Vec::new()];
        for action in actions {
            let lane = usize::from(action / 2);
            if action % 2 == 0 {
                let slot = match lane {
                    0 => lanes.execution(), 1 => lanes.publication(), _ => lanes.observation()
                };
                proptest::prop_assert_eq!(slot.is_ok(), held[lane].len() < limits[lane]);
                if let Ok(slot) = slot { held[lane].push(slot); }
            } else { held[lane].pop(); }
            proptest::prop_assert!(held.iter().zip(limits).all(|(slots, limit)| slots.len() <= limit));
        }
    }
}
