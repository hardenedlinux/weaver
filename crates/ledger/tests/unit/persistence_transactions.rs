use crate::persistence::{self, Session};

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
