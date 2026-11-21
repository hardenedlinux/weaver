// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{ConnectionChange, ConnectionOutcome, ConnectionProfile, ConnectionReceipt};
use crate::persistence::commit_observer::{Cut, Decision, Observer};
use crate::{Ledger, persistence};
use proptest::{prelude::any, prop_assert_eq, proptest, test_runner::Config as ProptestConfig};
use std::sync::Arc;
use weaver_contracts::{Error, body_digest};

fn change(id: &str, revision: Option<u64>, token: u8) -> ConnectionChange {
    ConnectionChange {
        operation_id: id.into(),
        connection: "http-client".into(),
        expected_revision: revision,
        profile: Some(ConnectionProfile {
            session: "session".into(),
            token_sha256: [token; 32],
        }),
    }
}
#[test]
fn retirement_and_aba_keep_clock_and_historical_receipts() {
    let dir = tempfile::tempdir().expect("connection configuration fixture");
    let path = dir.path().join("config.db");
    let mut ledger = Ledger::open(&path).expect("connection configuration fixture");
    let a = change("a", None, 1);
    let key = ledger
        .stage_connection(&a)
        .expect("connection configuration fixture");
    assert_eq!(
        ledger
            .connection_receipt(&key)
            .expect("connection configuration fixture"),
        None
    );
    let first = ledger
        .publish_connection(&key)
        .expect("connection configuration fixture");
    assert_eq!(first.revision, Some(0));
    let mut retired = change("retire", Some(0), 1);
    retired.profile = None;
    let rk = ledger
        .stage_connection(&retired)
        .expect("connection configuration fixture");
    ledger
        .publish_connection(&rk)
        .expect("connection configuration fixture");
    assert_eq!(
        ledger
            .connection_head("http-client")
            .expect("connection configuration fixture")
            .expect("connection configuration fixture")
            .profile,
        None
    );
    let b = change("again", Some(1), 1);
    let bk = ledger
        .stage_connection(&b)
        .expect("connection configuration fixture");
    ledger
        .publish_connection(&bk)
        .expect("connection configuration fixture");
    assert_eq!(
        ledger
            .connection_head("http-client")
            .expect("connection configuration fixture")
            .expect("connection configuration fixture")
            .revision,
        2
    );
    assert_eq!(
        ledger
            .publish_connection(&key)
            .expect("connection configuration fixture"),
        first
    );
    assert_eq!(
        ledger
            .connection_head("http-client")
            .expect("connection configuration fixture")
            .expect("connection configuration fixture")
            .revision,
        2
    );
    assert!(ledger.stage_connection(&change("a", Some(2), 2)).is_err());
    let abort = ledger
        .stage_connection(&change("abort", Some(2), 3))
        .expect("connection configuration fixture");
    assert_eq!(
        ledger
            .abort_connection(&abort)
            .expect("connection configuration fixture")
            .outcome,
        ConnectionOutcome::Aborted
    );
    assert_eq!(
        ledger
            .publish_connection(&abort)
            .expect("connection configuration fixture")
            .outcome,
        ConnectionOutcome::Aborted
    );
    drop(ledger);
    let ledger = Ledger::open(path).expect("connection configuration fixture");
    assert_eq!(
        ledger
            .connection_receipt(&key)
            .expect("connection configuration fixture"),
        Some(first)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn four_contenders_commit_one_durable_head() {
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        let dir = tempfile::tempdir().expect("connection configuration fixture");
        let path = dir.path().join("race.db");
        let keep = Ledger::open(&path).expect("connection configuration fixture");
        let gate = Arc::new(tokio::sync::Barrier::new(4));
        let mut jobs = Vec::new();
        for n in 1..=4 {
            let path = path.clone();
            let gate = gate.clone();
            jobs.push(tokio::spawn(async move {
                gate.wait().await;
                tokio::task::spawn_blocking(move || {
                    let mut ledger = Ledger::open(path).expect("connection configuration fixture");
                    let key = ledger
                        .stage_connection(&change(&format!("writer-{n}"), None, n))
                        .expect("connection configuration fixture");
                    ledger
                        .publish_connection(&key)
                        .expect("connection configuration fixture")
                })
                .await
                .expect("connection configuration fixture")
            }));
        }
        let mut committed = 0;
        for job in jobs {
            if job.await.expect("connection configuration fixture").outcome
                == ConnectionOutcome::Committed
            {
                committed += 1;
            }
        }
        assert_eq!(committed, 1);
        assert_eq!(
            keep.connection_head("http-client")
                .expect("connection configuration fixture")
                .expect("connection configuration fixture")
                .revision,
            0
        );
    })
    .await
    .expect("connection configuration fixture");
}

struct ExitAt(Cut);
#[test]
fn source_scoped_handles_cannot_administer_connections_and_corrupt_receipts_refuse() {
    let dir = tempfile::tempdir().expect("store");
    let mut ledger = Ledger::open(dir.path().join("scope.db")).expect("ledger");
    let key = ledger
        .stage_connection(&change("binding", None, 1))
        .expect("stage");
    ledger.publish_connection(&key).expect("publish");
    persistence::exec(
        &ledger.connection,
        "UPDATE connection_updates SET receipt=?1 WHERE operation_id=?2",
        persistence::params![
            serde_json::to_string(&ConnectionReceipt {
                key: key.clone(),
                outcome: ConnectionOutcome::Committed,
                revision: Some(9)
            })
            .expect("receipt"),
            key.operation_id.clone()
        ],
    )
    .expect("corrupt metadata");
    assert!(ledger.connection_receipt(&key).is_err());
    assert!(ledger.publish_connection(&key).is_err());
    ledger.source = Some(weaver_contracts::SourceIdentity {
        certificate_sha256: body_digest("cert"),
        public_key_sha256: body_digest("key"),
        credential_sha256: body_digest("credential"),
    });
    assert!(matches!(
        ledger.stage_connection(&change("source", Some(0), 2)),
        Err(Error::Denied)
    ));
    assert!(matches!(
        ledger.connection_head("http-client"),
        Err(Error::Denied)
    ));
    assert!(matches!(
        ledger.lease_connection("http-client"),
        Err(Error::Denied)
    ));
}
impl Observer for ExitAt {
    fn observe(&self, cut: Cut) -> Decision {
        if cut == self.0 {
            std::process::exit(71);
        }
        Decision::Continue
    }
}
#[test]
fn process_cut_child() {
    let Ok(cut) = std::env::var("WEAVER_CONNECTION_CUT") else {
        return;
    };
    let mut ledger = Ledger::open(
        std::env::var_os("WEAVER_CONNECTION_DB").expect("connection configuration fixture"),
    )
    .expect("connection configuration fixture");
    let proposal = change("crash", None, 1);
    let observer = Arc::new(ExitAt(if cut.ends_with("before") {
        Cut::BeforeCommit
    } else {
        Cut::AfterCommit
    }));
    if cut.starts_with("stage") {
        ledger.observe_provider_commit(observer.clone());
    }
    let key = ledger
        .stage_connection(&proposal)
        .expect("connection configuration fixture");
    ledger.observe_provider_commit(observer);
    let _ = ledger.publish_connection(&key);
    panic!("cut not reached");
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn four_real_process_cuts_recover_the_original_operation() {
    tokio::time::timeout(std::time::Duration::from_secs(30), async {
        let mut jobs = Vec::new();
        for cut in [
            "stage-before",
            "stage-after",
            "publish-before",
            "publish-after",
        ] {
            jobs.push(tokio::spawn(async move {
                let dir = tempfile::tempdir().expect("connection configuration fixture");
                let path = dir.path().join("cut.db");
                let out = tokio::process::Command::new(
                    std::env::current_exe().expect("connection configuration fixture"),
                )
                .args([
                    "connection_config::tests::process_cut_child",
                    "--exact",
                    "--nocapture",
                ])
                .env("WEAVER_CONNECTION_CUT", cut)
                .env("WEAVER_CONNECTION_DB", &path)
                .kill_on_drop(true)
                .output()
                .await
                .expect("connection configuration fixture");
                assert_eq!(
                    out.status.code(),
                    Some(71),
                    "{cut}: {}",
                    String::from_utf8_lossy(&out.stderr)
                );
                tokio::task::spawn_blocking(move || {
                    let mut ledger = Ledger::open(&path).expect("connection configuration fixture");
                    let proposal = change("crash", None, 1);
                    let key = ledger
                        .stage_connection(&proposal)
                        .expect("connection configuration fixture");
                    let before = ledger
                        .connection_receipt(&key)
                        .expect("connection configuration fixture");
                    assert_eq!(before.is_some(), cut == "publish-after");
                    let receipt = ledger
                        .publish_connection(&key)
                        .expect("connection configuration fixture");
                    assert_eq!(receipt.outcome, ConnectionOutcome::Committed);
                    assert_eq!(receipt.revision, Some(0));
                    assert_eq!(
                        ledger
                            .publish_connection(&key)
                            .expect("connection configuration fixture"),
                        receipt
                    );
                    assert_eq!(
                        ledger
                            .connection_head("http-client")
                            .expect("connection configuration fixture")
                            .expect("connection configuration fixture")
                            .revision,
                        0
                    );
                })
                .await
                .expect("connection configuration fixture");
            }));
        }
        for job in jobs {
            job.await.expect("connection configuration fixture");
        }
    })
    .await
    .expect("connection configuration fixture");
}

struct LoseAfter;
#[test]
fn live_listener_custody_closes_read_activation_and_publication_races() {
    let dir = tempfile::tempdir().expect("connection configuration fixture");
    let path = dir.path().join("lease.db");
    let mut ledger = Ledger::open(&path).expect("connection configuration fixture");
    let key = ledger
        .stage_connection(&change("first", None, 1))
        .expect("connection configuration fixture");
    ledger
        .publish_connection(&key)
        .expect("connection configuration fixture");
    let lease = ledger
        .lease_connection("http-client")
        .expect("connection configuration fixture");
    let next = ledger
        .stage_connection(&change("next", Some(0), 2))
        .expect("connection configuration fixture");
    assert!(ledger.publish_connection(&next).is_err());
    assert_eq!(
        ledger
            .connection_receipt(&next)
            .expect("connection configuration fixture"),
        None
    );
    assert_eq!(lease.head().revision, 0);
    drop(ledger);
    let mut another = Ledger::open(&path).expect("connection configuration fixture");
    assert!(another.publish_connection(&next).is_err());
    drop(lease);
    let receipt = another
        .publish_connection(&next)
        .expect("connection configuration fixture");
    assert_eq!(receipt.revision, Some(1));
}
impl Observer for LoseAfter {
    fn observe(&self, cut: Cut) -> Decision {
        if cut == Cut::AfterCommit {
            Decision::LoseAcknowledgment
        } else {
            Decision::Continue
        }
    }
}
#[test]
fn lost_reply_and_decision_storage_failure_do_not_partially_publish() {
    let dir = tempfile::tempdir().expect("connection configuration fixture");
    let path = dir.path().join("fault.db");
    let mut ledger = Ledger::open(&path).expect("connection configuration fixture");
    let key = ledger
        .stage_connection(&change("fault", None, 1))
        .expect("connection configuration fixture");
    persistence::script(&ledger.connection,"CREATE TRIGGER deny_connection BEFORE UPDATE OF receipt ON connection_updates BEGIN SELECT RAISE(ABORT,'injected decision failure'); END;").expect("connection configuration fixture");
    assert!(ledger.publish_connection(&key).is_err());
    assert_eq!(
        ledger
            .connection_head("http-client")
            .expect("connection configuration fixture"),
        None
    );
    assert_eq!(
        ledger
            .connection_receipt(&key)
            .expect("connection configuration fixture"),
        None
    );
    persistence::script(&ledger.connection, "DROP TRIGGER deny_connection")
        .expect("connection configuration fixture");
    ledger.observe_provider_commit(Arc::new(LoseAfter));
    assert!(ledger.publish_connection(&key).is_err());
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("connection configuration fixture");
    assert_eq!(
        ledger
            .publish_connection(&key)
            .expect("connection configuration fixture")
            .outcome,
        ConnectionOutcome::Committed
    );
    assert_eq!(
        ledger
            .connection_head("http-client")
            .expect("connection configuration fixture")
            .expect("connection configuration fixture")
            .revision,
        0
    );
}

proptest! {
    #![proptest_config(ProptestConfig {cases:64,rng_seed:proptest::test_runner::RngSeed::Fixed(293), ..ProptestConfig::default()})]
    #[test]
    fn generated_stale_replays_never_replace_the_current_snapshot(actions in proptest::collection::vec((any::<bool>(),1u8..=9),1..24)) {
        let dir=tempfile::tempdir().expect("connection configuration fixture");let mut ledger=Ledger::open(dir.path().join("history.db")).expect("connection configuration fixture");
        let mut expected=None;let mut retained=Vec::new();let mut profile=None;
        for (n,(fresh,token)) in actions.into_iter().enumerate(){
            let base=if fresh{expected}else{None};let proposal=change(&format!("op-{n}"),base,token);
            let key=ledger.stage_connection(&proposal).expect("connection configuration fixture");let receipt=ledger.publish_connection(&key).expect("connection configuration fixture");
            if base==expected {prop_assert_eq!(receipt.outcome,ConnectionOutcome::Committed);expected=Some(expected.map_or(0,|r|r+1));profile=proposal.profile;}
            else{prop_assert_eq!(receipt.outcome,ConnectionOutcome::Rejected);}
            retained.push((key,receipt));
            for (key,receipt) in &retained{prop_assert_eq!(ledger.publish_connection(key).expect("connection configuration fixture"),receipt.clone());}
            let head=ledger.connection_head("http-client").expect("connection configuration fixture").expect("connection configuration fixture");prop_assert_eq!(Some(head.revision),expected);prop_assert_eq!(head.profile,profile.clone());
        }
    }
}
