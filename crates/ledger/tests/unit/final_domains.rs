//! Actual deciding scopes, not a timing-only throughput surrogate.
use super::fixtures::{POLICY, proposal, task};
use std::{sync::mpsc, time::Duration};
use weaver_ledger::{
    Ledger,
    persistence::{Journal, Session},
};

#[test]
fn mvcc_final_domains_overlap_including_new_executor_connection() {
    exercise(false);
}
#[test]
fn mvcc_same_budget_and_history_family_keeps_final_order() {
    exercise(true);
}
fn exercise(shared: bool) {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("domains.db");
    let storage = Session::open_with_journal(&path, Journal::Mvcc).expect("owner");
    let mut first = Ledger::open(&path).expect("first");
    first.publish(None, POLICY, 1).expect("authority");
    let mut original = task();
    original.family = "a".into();
    first.register_task(&original).expect("first original");
    let mut left = proposal(0, 4);
    left.family = "a".into();
    let mut right = proposal(if shared { 1 } else { 0 }, 4);
    right.family = if shared { "a" } else { "b" }.into();
    if !shared {
        original.family = "b".into();
        first
            .register_task(&original)
            .expect("independent original");
    }
    first.enqueue(&left).expect("left reservation");
    first.enqueue(&right).expect("right reservation");
    let left_permit = first.consume("a", "n0").expect("left consumption");
    let prepared = if shared {
        let mut second = Ledger::open(&path).expect("second prepared worker");
        let permit = second
            .consume(&right.family, &right.node)
            .expect("second precommitted claim");
        Some((second, permit))
    } else {
        None
    };
    let (entered_tx, entered) = mpsc::channel();
    let (release, release_rx) = mpsc::channel();
    let first_job = std::thread::spawn(move || {
        first
            .dispatch(left_permit, |_| {
                entered_tx.send(()).expect("first effect");
                release_rx.recv().expect("bounded test release");
            })
            .expect("first final use");
    });
    entered
        .recv_timeout(Duration::from_secs(2))
        .expect("first entered");
    let (other_tx, other) = mpsc::channel();
    let other_path = path.clone();
    let (attempt_tx, attempted) = mpsc::channel();
    let second_job = std::thread::spawn(move || {
        let (mut second, permit) = if let Some(prepared) = prepared {
            prepared
        } else {
            let mut second =
                Ledger::open(&other_path).expect("new executor connection during first send");
            let permit = second
                .consume(&right.family, &right.node)
                .expect("second consumption");
            (second, permit)
        };
        attempt_tx
            .send(())
            .expect("candidate reaches final dispatch");
        second
            .dispatch(permit, |_| {
                other_tx.send(()).expect("second effect");
            })
            .expect("second final use");
    });
    attempted
        .recv_timeout(Duration::from_secs(2))
        .expect("second candidate ready");
    let overlapped = other
        .recv_timeout(Duration::from_millis(if shared { 40 } else { 2000 }))
        .is_ok();
    release.send(()).expect("release first");
    first_job.join().expect("first natural drain");
    second_job.join().expect("second natural drain");
    assert_eq!(
        overlapped, !shared,
        "concurrency must follow original budget/history domain"
    );
    let recovered = Ledger::open(&path).expect("observer");
    assert_eq!(
        recovered.held("a").expect("original exposure"),
        if shared { 8 } else { 4 }
    );
    if !shared {
        assert_eq!(recovered.held("b").expect("independent exposure"), 4);
    }
    drop(recovered);
    storage.close().expect("owner drains");
}
