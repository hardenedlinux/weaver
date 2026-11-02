use crate::persistence::{self, Session};

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
        Session::open_with_journal(path, persistence::Journal::Mvcc).is_err(),
        "second process acquired live MVCC custody"
    );
}

#[test]
fn mvcc_process_custody_refuses_a_second_process() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("owner.db");
    let storage = Session::open_with_journal(&path, persistence::Journal::Mvcc).expect("owner");
    let output = std::process::Command::new(std::env::current_exe().expect("test image"))
        .args([
            "--exact",
            "persistence::scope::tests::mvcc_second_process_probe",
            "--nocapture",
        ])
        .env("WEAVER_MVCC_CUSTODY_PROBE", &path)
        .output()
        .expect("natural child exit");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("1 passed"));
    storage.close().expect("owner drains");
    Session::open_with_journal(&path, persistence::Journal::Mvcc)
        .expect("new owner after release")
        .close()
        .expect("close");
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
fn mvcc_disjoint_admissions_have_overlapping_native_writes() {
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
