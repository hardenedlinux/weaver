// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::persistence::{self, Session};

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
#[ignore = "bounded performance probe using the real native transaction scope"]
fn provider_begin_temp_pager_probe() {
    use crate::persistence::timing::thread_cpu_time;
    use std::time::Instant;
    let directory = tempfile::tempdir().expect("store");
    let path = directory.path().join("temp-pager.db");
    let mut owner =
        Session::open_with_journal(&path, persistence::Journal::Mvcc).expect("native owner");
    roots(&mut owner);
    let variants = ["default", "prewarm-file", "memory-diagnostic"];
    for round in 0..24 {
        for offset in 0..variants.len() {
            let variant = variants[(round + offset) % variants.len()];
            let mut session = Session::open(&path).expect("new connection");
            let setup_wall = Instant::now();
            let setup_cpu = thread_cpu_time().expect("thread CPU");
            match variant {
                "default" => {}
                "prewarm-file" => {
                    let objects: i64 = persistence::one(
                        &session,
                        "SELECT count(*) FROM temp.sqlite_schema",
                        (),
                        |row| row.get(0),
                    )
                    .expect("prepare connection-local TEMP pager");
                    assert_eq!(objects, 0);
                }
                "memory-diagnostic" => {
                    persistence::exec(&session, "PRAGMA temp_store=MEMORY", ())
                        .expect("diagnostic TEMP mode");
                }
                _ => unreachable!(),
            }
            let setup_cpu = thread_cpu_time().expect("thread CPU") - setup_cpu;
            let setup_wall = setup_wall.elapsed();
            session.trace_provider_scopes("a", None);
            for pass in 0..2 {
                let before = session.timings();
                let transaction =
                    persistence::begin_family(&mut session, "a").expect("native BEGIN");
                drop(transaction);
                session.require_quiescent().expect("native rollback");
                let timing = session.timings().since(before);
                assert_eq!(timing.transaction_begin_cpu.attempts, 1);
                assert_eq!(timing.transaction_begin_prepare.attempts, 1);
                println!(
                    "weaver-temp-pager {{\"round\":{round},\"arm\":\"{variant}\",\"pass\":{pass},\"setupWallNS\":{},\"setupCpuNS\":{},\"beginWallNS\":{},\"beginCpuNS\":{},\"prepareCpuNS\":{}}}",
                    setup_wall.as_nanos(),
                    setup_cpu.as_nanos(),
                    timing.transaction_begin.nanos,
                    timing.transaction_begin_cpu.nanos,
                    timing.transaction_begin_prepare_cpu.nanos
                );
            }
            let journal: String =
                persistence::one(&session, "PRAGMA journal_mode", (), |row| row.get(0))
                    .expect("journal");
            let synchronous: i64 =
                persistence::one(&session, "PRAGMA synchronous", (), |row| row.get(0))
                    .expect("sync");
            let foreign_keys: i64 =
                persistence::one(&session, "PRAGMA foreign_keys", (), |row| row.get(0))
                    .expect("foreign keys");
            assert_eq!(
                (journal.as_str(), synchronous, foreign_keys),
                ("mvcc", 2, 1)
            );
            session.close().expect("clean connection");
        }
    }
    let holds: i64 = persistence::one(&owner, "SELECT sum(held) FROM budget_domains", (), |row| {
        row.get(0)
    })
    .expect("unchanged reservations");
    assert_eq!(holds, 0);
    owner.close().expect("natural owner drain");
}

struct CommitFault {
    after: bool,
}
impl persistence::commit_observer::Observer for CommitFault {
    fn observe(
        &self,
        cut: persistence::commit_observer::Cut,
    ) -> persistence::commit_observer::Decision {
        use persistence::commit_observer::{Cut, Decision};
        match (self.after, cut) {
            (false, Cut::BeforeCommit) => Decision::Rollback,
            (true, Cut::AfterCommit) => Decision::LoseAcknowledgment,
            _ => Decision::Continue,
        }
    }
}

#[test]
fn applied_commit_with_lost_ack_cannot_park_as_provider() {
    let directory = tempfile::tempdir().expect("store");
    let path = directory.path().join("provider-reuse-lost-ack.db");
    let mut ledger = crate::Ledger::open(&path).expect("ledger");
    persistence::exec(
        &ledger.connection,
        "CREATE TABLE probe(id INTEGER PRIMARY KEY)",
        (),
    )
    .expect("probe schema");
    ledger.connection.commit_observer = Some(std::sync::Arc::new(CommitFault { after: true }));
    let tx = persistence::begin(&mut ledger.connection).expect("writer");
    persistence::exec(&tx, "INSERT INTO probe VALUES(1)", ()).expect("stage marker");
    assert!(tx.commit_provider().is_err());
    assert!(
        ledger
            .connection
            .is_autocommit()
            .expect("native transaction ended")
    );
    assert!(ledger.park_provider_connection().is_err());
    let recovered = crate::Ledger::open(&path).expect("fresh physical connection");
    let marker: i64 = persistence::one(&recovered.connection, "SELECT id FROM probe", (), |row| {
        row.get(0)
    })
    .expect("applied marker recovered");
    assert_eq!(marker, 1);
}
proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(16))]
    #[test]
    fn turso_applied_commit_without_ack_poison_is_not_reusable(after in proptest::bool::ANY, mvcc in proptest::bool::ANY, held in 1i64..1000) {
        let directory = tempfile::tempdir().expect("store");
        let path = directory.path().join("fault.db");
        let journal=if mvcc {persistence::Journal::Mvcc}else{persistence::Journal::Wal};
        let mut session=Session::open_with_journal(&path,journal).expect("native session");
        persistence::script(&session,"CREATE TABLE exposure(id INTEGER PRIMARY KEY, marker INTEGER, held INTEGER);").expect("schema");
        persistence::exec(&session,"INSERT INTO exposure VALUES(1,1,?1)",[held]).expect("original reservation");
        session.commit_observer=Some(std::sync::Arc::new(CommitFault { after }));
        let tx=persistence::begin(&mut session).expect("writer");
        persistence::exec(&tx,"UPDATE exposure SET marker=2 WHERE id=1",()).expect("stage callback observation");
        proptest::prop_assert!(tx.commit_provider().is_err());
        proptest::prop_assert!(session.is_autocommit().expect("native transaction ended"));
        proptest::prop_assert!(session.require_quiescent().is_err(),"autocommit is not acknowledgment");
        proptest::prop_assert!(persistence::begin(&mut session).is_err(),"old worker reused poisoned custody");
        drop(session);
        let recovered=Session::open_with_journal(&path,journal).expect("recovered native owner");
        let (marker,retained):(i64,i64)=persistence::one(&recovered,"SELECT marker,held FROM exposure WHERE id=1",(),|r|Ok((r.get(0)?,r.get(1)?))).expect("actual persisted values");
        proptest::prop_assert_eq!(marker,if after {2}else{1});
        proptest::prop_assert_eq!(retained,held);
        recovered.close().expect("fresh recovery drains");
    }
}

// Native transaction tests intentionally omit task admission. Their deciding lock
// identities still come from persisted roots, never from caller-selected stripes.
fn roots(session: &mut Session) {
    session.initialize_ledger().expect("ledger schema");
    for family in ["a", "b"] {
        persistence::exec(
            session,
            "INSERT INTO original_tasks VALUES(?1,?1,?1,'native-probe','native-probe','null')",
            [family],
        )
        .expect("native lock identity fixture");
        persistence::exec(
            session,
            "INSERT INTO budget_domains VALUES(?1,?1,20,20,0,1)",
            [family],
        )
        .expect("budget root");
        persistence::exec(
            session,
            "INSERT INTO history_domains VALUES(?1,?1,0,1)",
            [family],
        )
        .expect("history root");
        persistence::exec(
            session,
            "INSERT INTO execution_origins VALUES(?1,?1,?2,?1,?1)",
            [
                family,
                serde_json::to_string(&weaver_contracts::DomainBinding {
                    origin: family.into(),
                    budget: family.into(),
                    history: family.into(),
                    budget_limit: 20,
                })
                .expect("immutable binding")
                .as_str(),
            ],
        )
        .expect("origin");
        persistence::exec(
            session,
            "INSERT INTO family_origins VALUES(?1,?1)",
            [family],
        )
        .expect("family");
    }
}

#[test]
fn mvcc_second_process_probe() {
    let Some(path) = std::env::var_os("WEAVER_MVCC_CUSTODY_PROBE") else {
        return;
    };
    assert!(
        Session::open_with_journal(
            path,
            if std::env::var_os("WEAVER_TEST_WAL_CUSTODY").is_some() {
                persistence::Journal::Wal
            } else {
                persistence::Journal::Mvcc
            }
        )
        .is_err(),
        "second process acquired live execution custody"
    );
}

#[test]
fn mvcc_process_custody_refuses_a_second_process() {
    for journal in [persistence::Journal::Wal, persistence::Journal::Mvcc] {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("owner.db");
        let storage = Session::open_with_journal(&path, journal).expect("owner");
        let retained_owner = storage.execution_owner();
        storage
            .close()
            .expect("session retired, logical role retained");
        let output = std::process::Command::new(std::env::current_exe().expect("test image"))
            .args([
                "--exact",
                "persistence::scope::tests::mvcc_second_process_probe",
                "--nocapture",
            ])
            .env("WEAVER_MVCC_CUSTODY_PROBE", &path)
            .envs(if journal == persistence::Journal::Wal {
                vec![("WEAVER_TEST_WAL_CUSTODY", "1")]
            } else {
                vec![]
            })
            .output()
            .expect("natural child exit");
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(String::from_utf8_lossy(&output.stdout).contains("1 passed"));
        drop(retained_owner);
        Session::open_with_journal(&path, journal)
            .expect("new owner after release")
            .close()
            .expect("close");
    }
}

#[test]
fn mvcc_conflicting_snapshot_aborts_without_a_reusable_session() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("conflict.db");
    let mut first = Session::open_with_journal(&path, persistence::Journal::Mvcc).expect("owner");
    roots(&mut first);
    persistence::script(&first, "CREATE TABLE exposure(id INTEGER PRIMARY KEY, held INTEGER); INSERT INTO exposure VALUES(1,3);").expect("schema");
    let mut second = Session::open(&path).expect("second connection");
    let one = persistence::begin_family(&mut first, "a").expect("first snapshot");
    let two = persistence::begin_family(&mut second, "b")
        .expect("fault: different family targets same row");
    persistence::exec(&one, "UPDATE exposure SET held=4 WHERE id=1", ()).expect("first write");
    let write = persistence::exec(&two, "UPDATE exposure SET held=0 WHERE id=1", ());
    one.commit().expect("winner");
    if write.is_ok() {
        assert!(two.commit().is_err(), "conflicting refund committed");
        assert!(
            second.require_quiescent().is_err(),
            "commit conflict cannot reenter"
        );
    } else {
        drop(two);
    }
    let observer = Session::open(&path).expect("authoritative observer");
    let held: i64 = persistence::one(&observer, "SELECT held FROM exposure WHERE id=1", (), |r| {
        r.get(0)
    })
    .expect("retained hold");
    assert_eq!(held, 4, "conflict released original exposure");
}

#[test]
fn mvcc_disjoint_admissions_have_overlapping_turso_writes() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("parallel.db");
    let mut first =
        Session::open_with_journal(&path, persistence::Journal::Mvcc).expect("MVCC owner");
    roots(&mut first);
    persistence::script(
        &first,
        "CREATE TABLE admissions(id INTEGER PRIMARY KEY, held INTEGER);",
    )
    .expect("schema");
    let mut second = Session::open(&path).expect("shared native database");
    let one = persistence::begin_family(&mut first, "a").expect("first snapshot");
    let two = persistence::begin_family(&mut second, "b").expect("overlapping snapshot");
    persistence::exec(&one, "INSERT INTO admissions VALUES(1,3)", ()).expect("first write");
    persistence::exec(&two, "INSERT INTO admissions VALUES(2,4)", ())
        .expect("second write before first commit");
    one.commit().expect("first commit");
    two.commit().expect("independent second commit");
    let held: i64 = persistence::one(&second, "SELECT SUM(held) FROM admissions", (), |r| {
        r.get(0)
    })
    .expect("both outcomes");
    assert_eq!(held, 7);
    first.close().expect("first close");
    second.close().expect("second close");
    let recovered = Session::open_with_journal(&path, persistence::Journal::Mvcc)
        .expect("durable MVCC restart");
    let held: i64 = persistence::one(&recovered, "SELECT SUM(held) FROM admissions", (), |r| {
        r.get(0)
    })
    .expect("recovered original holds");
    assert_eq!(held, 7);
}

#[test]
fn mvcc_final_scope_excludes_admission_and_publication() {
    use std::{sync::mpsc, time::Duration};
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("gate.db");
    let mut final_owner =
        Session::open_with_journal(&path, persistence::Journal::Mvcc).expect("owner");
    roots(&mut final_owner);
    let mut admission = Session::open(&path).expect("admission");
    let final_scope = persistence::begin(&mut final_owner).expect("final boundary");
    let (attempt, started) = mpsc::channel();
    let (done, finished) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        attempt.send(()).expect("attempt");
        let tx = persistence::begin_family(&mut admission, "a").expect("admission after final use");
        tx.commit().expect("commit");
        done.send(()).expect("completion");
    });
    started
        .recv_timeout(Duration::from_secs(1))
        .expect("worker started");
    assert!(finished.recv_timeout(Duration::from_millis(20)).is_err());
    final_scope.commit().expect("release final boundary");
    finished
        .recv_timeout(Duration::from_secs(1))
        .expect("progress after release");
    worker.join().expect("natural worker exit");
}

#[test]
fn mvcc_mode_never_converts_existing_wal_or_changes_live_profile() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("modes.db");
    let wal = Session::open(&path).expect("WAL");
    persistence::script(&wal, "CREATE TABLE retained(id INTEGER PRIMARY KEY);")
        .expect("durable image");
    assert!(Session::open_with_journal(&path, persistence::Journal::Mvcc).is_err());
    wal.close().expect("close");
    assert!(Session::open_with_journal(&path, persistence::Journal::Mvcc).is_err());
    let wal = Session::open(&path).expect("original WAL remains");
    let mode: String =
        persistence::one(&wal, "PRAGMA journal_mode", (), |r| r.get(0)).expect("journal");
    assert_eq!(mode, "wal");
}

#[test]
fn failed_commit_releases_writer_and_poisoned_session_cannot_reenter() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("commit-failure.db");
    let mut session = Session::open(&path).expect("session");
    persistence::script(&session,"CREATE TABLE parents(id INTEGER PRIMARY KEY); CREATE TABLE children(parent_id INTEGER REFERENCES parents(id) DEFERRABLE INITIALLY DEFERRED);").expect("deferred constraint schema");
    let transaction = persistence::begin(&mut session).expect("immediate writer");
    persistence::exec(&transaction, "INSERT INTO children VALUES(7)", ())
        .expect("staged deferred write");
    assert!(
        transaction.commit().is_err(),
        "unresolved foreign key must reject commit"
    );
    assert!(
        session.require_quiescent().is_err(),
        "a failed commit cannot become a reusable permit"
    );
    assert!(
        persistence::begin(&mut session).is_err(),
        "old worker must reopen from authoritative state"
    );
    let mut replacement = Session::open(&path).expect("replacement session");
    replacement
        .busy_timeout(std::time::Duration::from_millis(20))
        .expect("bounded lock probe");
    let transaction =
        persistence::begin(&mut replacement).expect("failed commit did not strand the writer");
    let count: i64 = persistence::one(&transaction, "SELECT COUNT(*) FROM children", (), |r| {
        r.get(0)
    })
    .expect("original image");
    assert_eq!(count, 0, "no partial committed child survived");
    persistence::exec(&transaction, "INSERT INTO parents VALUES(7)", ())
        .expect("fresh authoritative write");
    transaction.commit().expect("replacement progress");
    replacement.close().expect("replacement clean close");
    assert!(
        session.close().is_err(),
        "unknown outcome cannot report clean reusable completion"
    );
}
