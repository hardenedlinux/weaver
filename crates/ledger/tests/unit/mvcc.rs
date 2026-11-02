//! Real native MVCC event histories; original claims survive lost observations.
use super::fixtures::{POLICY, initialized, proposal};
use proptest::{collection, prop_assert, prop_assert_eq, proptest, test_runner::Config};
use weaver_ledger::{
    Ledger,
    persistence::{Journal, Session},
};

#[test]
fn mvcc_source_enrollment_ignores_only_exact_native_recovery_metadata() {
    for fault in 0..3 {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("enrollment.db");
        let storage = Session::open_with_journal(&path, Journal::Mvcc).expect("MVCC");
        let mut ledger = Ledger::open(&path).expect("schema");
        match fault {
            1 => weaver_ledger::persistence::script(&storage, "CREATE TABLE __tursoX_internal_mvcc_meta(v INTEGER); INSERT INTO __tursoX_internal_mvcc_meta VALUES(1);").expect("residual shadow"),
            2 => weaver_ledger::persistence::script(&storage, "CREATE TABLE sqliteX(v INTEGER); INSERT INTO sqliteX VALUES(1);").expect("residual row"),
            _ => (),
        }
        let result =
            ledger.with_authenticated_source(&super::source_authority::identity(0), |_| Ok(()));
        assert_eq!(
            result.is_ok(),
            fault == 0,
            "native metadata cannot hide application residue"
        );
    }
}

proptest! {
    #![proptest_config(Config::with_cases(32))]
    #[test]
    fn mvcc_concurrent_family_budget_has_one_original_reservation(distinct: bool) {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("budget.db");
        let storage = Session::open_with_journal(&path, Journal::Mvcc).expect("MVCC");
        let mut first = initialized(&path);
        let mut second = Ledger::open(&path).expect("second connection");
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let other = barrier.clone();
        let job = std::thread::spawn(move || {other.wait(); second.enqueue(&proposal(if distinct {1} else {0},12)).is_ok()});
        barrier.wait();
        let accepted = first.enqueue(&proposal(0,12)).is_ok();
        let other_accepted = job.join().expect("worker natural exit");
        prop_assert_eq!(usize::from(accepted)+usize::from(other_accepted), if distinct {1} else {2});
        prop_assert_eq!(first.held("family").expect("shared budget"), 12);
        drop(first);
        storage.close().expect("drain");
    }
    #[test]
    fn mvcc_restart_revoke_reply_loss_cannot_duplicate_or_refund(events in collection::vec(0u8..6, 1..32)) {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("history.db");
        let mut storage = Some(Session::open_with_journal(&path, Journal::Mvcc).expect("MVCC"));
        let mut ledger = initialized(&path);
        ledger.enqueue(&proposal(0, 12)).expect("original hold");
        let mut permit = None;
        let mut calls = 0;
        let mut revision = 0;
        let mut revoked = false;
        for event in events {
            match event {
                0 => { if let Ok(consumed) = ledger.consume("family", "n0") { permit = Some(consumed); } }
                1 => { if let Some(consumed) = permit.take() {
                    let before = calls;
                    let _ = ledger.dispatch(consumed, |_| { calls += 1; });
                    if revoked { prop_assert_eq!(calls, before); }
                } }
                2 => { // Complete native teardown, then restart from the original image.
                    drop(ledger);
                    storage.take().expect("storage lease").close().expect("drain");
                    storage = Some(Session::open_with_journal(&path, Journal::Mvcc).expect("recover"));
                    ledger = Ledger::open(&path).expect("new worker");
                }
                3 => {
                    revision = ledger.publish(Some(revision), "forbid(principal, action, resource);", revision+2).expect("revoke");
                    revoked = true;
                }
                4 => { // Simulate a lost consume response; discard the private capability.
                    let _ = ledger.consume("family", "n0");
                }
                _ => {
                    revision = ledger.publish(Some(revision), POLICY, revision+2).expect("new authority");
                    revoked = false;
                }
            }
            prop_assert!(calls <= 1);
            prop_assert_eq!(ledger.held("family").expect("held exposure"), 12);
        }
    }
}
