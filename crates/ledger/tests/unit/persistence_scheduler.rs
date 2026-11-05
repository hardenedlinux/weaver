// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Scheduler, Scope, State, Ticket};
use proptest::{prop_assert_eq, proptest};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

fn scope(roots: [u8; 3]) -> Scope {
    Scope::Domains(roots.map(|id| id.to_string()))
}

proptest! {
    #[test]
    fn grants_depend_only_on_exact_older_or_active_conflicts(
        roots in proptest::collection::vec(proptest::array::uniform3(0u8..16), 0..32),
        active in proptest::array::uniform3(0u8..16),
        candidate in proptest::array::uniform3(0u8..16), split in 0usize..32,
    ) {
        let split = split.min(roots.len());
        let mut state = State {
            waiting: roots.iter().enumerate().map(|(id, roots)| Ticket {
                id: id as u64, scope: scope(*roots),
            }).collect(),
            active: vec![Ticket {id: 32, scope: scope(active)}],
            ..State::default()
        };
        state.waiting.insert(split, Ticket {id: 33, scope: scope(candidate)});
        let conflict = (0..3).any(|i| {
            active[i] == candidate[i] || roots.iter().take(split).any(|root| root[i] == candidate[i])
        });
        prop_assert_eq!(state.eligible(split), !conflict);
    }
}

#[test]
fn cancelled_waiter_has_no_custody_and_global_release_changes_generation() {
    let scheduler = Scheduler::default();
    let held = scheduler
        .acquire(scope([1, 2, 3]), None)
        .expect("first domain grant");
    assert!(scheduler.acquire(Scope::All, Some(&|| true)).is_err());
    assert!(scheduler.acquire(scope([2, 3, 1]), None).is_ok());
    assert_eq!(scheduler.generation().expect("initial generation"), 0);
    drop(held);
    drop(scheduler.acquire(Scope::All, None).expect("global grant"));
    assert_eq!(scheduler.generation().expect("advanced generation"), 1);
}

#[test]
fn waiting_multi_root_range_precedes_younger_conflicts() {
    let scheduler = Scheduler::default();
    let (queued, observed) = mpsc::channel();
    let (order, granted) = mpsc::channel();
    let deadline = Instant::now() + Duration::from_secs(2);
    thread::scope(|threads| {
        let held = scheduler
            .acquire(scope([0, 1, 2]), None)
            .expect("held domain grant");
        for (name, roots) in [("older", [0, 3, 4]), ("younger", [1, 3, 5])] {
            let queue = queued.clone();
            let order = order.clone();
            let owner = &scheduler;
            threads.spawn(move || {
                let announced = AtomicBool::new(false);
                let signal = || {
                    if !announced.swap(true, Ordering::Relaxed) {
                        let _ = queue.send(());
                    }
                    Instant::now() >= deadline
                };
                if let Ok(_grant) = owner.acquire(scope(roots), Some(&signal)) {
                    let _ = order.send(name);
                }
            });
            observed
                .recv_timeout(Duration::from_secs(1))
                .expect("ticket registration");
        }
        let disjoint = scheduler
            .acquire(scope([2, 0, 1]), Some(&|| Instant::now() >= deadline))
            .expect("disjoint grant");
        drop(held);
        assert_eq!(
            granted
                .recv_timeout(Duration::from_secs(1))
                .expect("older grant"),
            "older"
        );
        assert_eq!(
            granted
                .recv_timeout(Duration::from_secs(1))
                .expect("younger grant"),
            "younger"
        );
        drop(disjoint);
    });
}
