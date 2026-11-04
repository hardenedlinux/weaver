// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::fixtures::{initialized, proposal};
use std::{
    sync::{
        Arc, Barrier,
        atomic::{AtomicUsize, Ordering},
    },
    thread,
};
use weaver_ledger::Ledger;

#[test]
fn concurrent_consumers_invoke_once() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("ledger.db");
    let mut ledger = initialized(&path);
    ledger.enqueue(&proposal(0, 12)).expect("queue");
    drop(ledger);
    let barrier = Arc::new(Barrier::new(8));
    let calls = Arc::new(AtomicUsize::new(0));
    let workers: Vec<_> = (0..8)
        .map(|_| {
            let path = path.clone();
            let barrier = barrier.clone();
            let calls = calls.clone();
            thread::spawn(move || {
                let mut ledger = Ledger::open(&path).expect("open");
                barrier.wait();
                if let Ok(permit) = ledger.consume("family", "n0") {
                    ledger
                        .dispatch(permit, |_| {
                            calls.fetch_add(1, Ordering::SeqCst);
                        })
                        .expect("dispatch");
                }
            })
        })
        .collect();
    for worker in workers {
        worker.join().expect("join");
    }
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        Ledger::open(&path)
            .expect("open")
            .held("family")
            .expect("held"),
        12
    );
}

#[test]
fn concurrent_nodes_share_one_capacity() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("ledger.db");
    drop(initialized(&path));
    let barrier = Arc::new(Barrier::new(8));
    let workers: Vec<_> = (0u8..8)
        .map(|node| {
            let path = path.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                let mut ledger = Ledger::open(&path).expect("open");
                barrier.wait();
                ledger.enqueue(&proposal(node, 12)).is_ok()
            })
        })
        .collect();
    assert_eq!(
        workers
            .into_iter()
            .filter_map(|w| w.join().ok())
            .filter(|ok| *ok)
            .count(),
        1
    );
    assert_eq!(
        Ledger::open(&path)
            .expect("open")
            .held("family")
            .expect("held"),
        12
    );
}
