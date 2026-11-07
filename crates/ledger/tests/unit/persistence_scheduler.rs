// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Access, Scheduler, Scope, State, Ticket};
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
    Scope::Domains(roots.map(|id| id.to_string()).into())
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
            waiting: roots.iter().enumerate().map(|(id, roots)| Ticket { access: Access::Exclusive,
                id: id as u64, scope: scope(*roots),
            }).collect(),
            active: vec![Ticket { access: Access::Exclusive,id: 32, scope: scope(active)}],
            ..State::default()
        };
        state.waiting.insert(split, Ticket { access: Access::Exclusive,id: 33, scope: scope(candidate)});
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

proptest! {
    #[test]
    fn read_custody_conflicts_with_every_overlapping_writer(
        a in proptest::array::uniform3(0u8..8), b in proptest::array::uniform3(0u8..8),
        read_a in proptest::bool::ANY, read_b in proptest::bool::ANY,
    ) {
        let left = Ticket { id: 0, scope: scope(a), access: if read_a { Access::OriginWrite } else { Access::Exclusive } };
        let right = Ticket { id: 1, scope: scope(b), access: if read_b { Access::OriginWrite } else { Access::Exclusive } };
        let conflict = if read_a && read_b { a[0] == b[0] } else { (0..3).any(|i| a[i] == b[i]) };
        prop_assert_eq!(left.conflicts(&right), conflict);
        prop_assert_eq!(right.conflicts(&left), conflict);
        let global = Ticket { id: 2, scope: Scope::All, access: Access::OriginWrite };
        prop_assert_eq!(left.conflicts(&global), true);
    }
}

#[test]
fn compatible_origins_share_reads_but_an_older_writer_blocks_younger_readers() {
    let scheduler = Scheduler::default();
    let first = scheduler
        .acquire_origin(scope([1, 2, 3]), None)
        .expect("first reader");
    let peer = scheduler
        .acquire_origin(scope([4, 2, 3]), None)
        .expect("peer shares budget/history");
    assert!(
        scheduler
            .acquire_origin(scope([1, 5, 6]), Some(&|| true))
            .is_err()
    );
    drop(peer);
    let (announced, queue) = mpsc::channel();
    let (ordered, result) = mpsc::channel();
    let deadline = Instant::now() + Duration::from_secs(2);
    thread::scope(|threads| {
        for (writer, roots) in [(true, [7, 2, 8]), (false, [9, 2, 3])] {
            let announced = announced.clone();
            let ordered = ordered.clone();
            let owner = &scheduler;
            threads.spawn(move || {
                let once = AtomicBool::new(false);
                let signal = || {
                    if !once.swap(true, Ordering::Relaxed) {
                        let _ = announced.send(());
                    }
                    Instant::now() >= deadline
                };
                let granted = if writer {
                    owner.acquire(scope(roots), Some(&signal))
                } else {
                    owner.acquire_origin(scope(roots), Some(&signal))
                };
                if let Ok(_grant) = granted {
                    ordered.send(writer).expect("order");
                }
            });
            queue
                .recv_timeout(Duration::from_secs(1))
                .expect("registered");
        }
        assert!(result.try_recv().is_err());
        drop(first);
        assert!(
            result
                .recv_timeout(Duration::from_secs(1))
                .expect("writer first")
        );
        assert!(
            !result
                .recv_timeout(Duration::from_secs(1))
                .expect("reader after writer")
        );
    });
}
