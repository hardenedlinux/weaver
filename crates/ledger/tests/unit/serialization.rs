// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use super::fixtures::{POLICY, initialized, proposal};
use std::{sync::mpsc, thread, time::Duration};
use weaver_ledger::Ledger;

#[test]
fn effective_publication_cannot_overtake_the_locked_send_boundary() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("ledger.db");
    let mut ledger = initialized(&path);
    ledger.enqueue(&proposal(0, 5)).expect("queue");
    let permit = ledger.consume("family", "n0").expect("consume");
    let (inside_tx, inside_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let sender = thread::spawn(move || {
        ledger
            .dispatch(permit, |_| {
                inside_tx.send(()).expect("signal");
                release_rx.recv().expect("release");
            })
            .expect("dispatch")
    });
    inside_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("inside deciding lock");
    let (committed_tx, committed_rx) = mpsc::channel();
    let publisher = thread::spawn(move || {
        let mut ledger = Ledger::open(path).expect("publisher");
        let revision = ledger.publish(Some(0), POLICY, 2).expect("publish");
        committed_tx.send(revision).expect("signal commit");
    });
    assert!(
        committed_rx
            .recv_timeout(Duration::from_millis(50))
            .is_err()
    );
    release_tx.send(()).expect("release");
    sender.join().expect("sender");
    assert_eq!(
        committed_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("publication"),
        1
    );
    publisher.join().expect("publisher");
}
