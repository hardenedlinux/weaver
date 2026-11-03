//! Test-only control of actual native commit cuts, not a production fault RPC.
use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
    sync::{Arc, OnceLock},
    time::Duration,
};
use weaver_ledger::{
    Ledger,
    persistence::{
        self,
        commit_observer::{Cut, Decision, Observer},
    },
};

struct CommitObserver {
    path: String,
    selected: Cut,
}
static OBSERVER: OnceLock<Arc<CommitObserver>> = OnceLock::new();

impl Observer for CommitObserver {
    fn observe(&self, cut: Cut) -> Decision {
        if cut != self.selected {
            return Decision::Continue;
        }
        let mut socket = UnixStream::connect(&self.path).expect("private commit observer");
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("bounded fault window");
        socket
            .set_write_timeout(Some(Duration::from_secs(3)))
            .expect("bounded delivery");
        // A different native connection observes committed bytes, never the staged
        // value on the writer. This query cannot grant execution or settle usage.
        let marker = durable_marker();
        socket
            .write_all(format!("{cut:?} {marker}\n").as_bytes())
            .expect("actual cut");
        let mut command = [0];
        socket
            .read_exact(&mut command)
            .expect("fault consumed within original bound");
        match command[0] {
            b'c' => Decision::Continue,
            b'r' => Decision::Rollback,
            b'l' => Decision::LoseAcknowledgment,
            _ => panic!("unknown test decision"),
        }
    }
}
fn durable_marker() -> i64 {
    let path = std::env::var("WEAVER_DB").expect("fixture database");
    if !std::path::Path::new(&path).exists() {
        return 0;
    }
    let journal = if std::env::var("WEAVER_STORAGE_JOURNAL").as_deref() == Ok("mvcc") {
        persistence::Journal::Mvcc
    } else {
        persistence::Journal::Wal
    };
    let session =
        persistence::Session::open_with_journal(path, journal).expect("independent native reader");
    let table: bool = persistence::one(
        &session,
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='provider_runs')",
        (),
        |r| r.get(0),
    )
    .expect("schema read");
    if !table {
        return 0;
    }
    persistence::one(
        &session,
        "SELECT COALESCE(MAX(dispatched),0) FROM provider_runs",
        (),
        |r| r.get(0),
    )
    .expect("persisted dispatch marker")
}
pub(crate) fn attach(ledger: &mut Ledger) {
    if let Some(observer) = OBSERVER.get() {
        ledger.observe_provider_commit(observer.clone());
    }
}
#[test]
#[ignore = "Go owns real HTTPS/gRPC and subprocess crash injection"]
fn serve_observed_gateway() {
    let path = std::env::var("WEAVER_TEST_COMMIT_SOCKET").expect("test controller");
    let selected = match std::env::var("WEAVER_TEST_COMMIT_CUT").as_deref() {
        Ok("before") => Cut::BeforeCommit,
        Ok("after") => Cut::AfterCommit,
        _ => panic!("explicit commit cut required"),
    };
    // Restart reads the recovered store before any provider RPC can modify it.
    let mut socket = UnixStream::connect(&path).expect("startup observer");
    socket
        .write_all(format!("Boot {}\n", durable_marker()).as_bytes())
        .expect("recovery observation");
    assert!(
        OBSERVER
            .set(Arc::new(CommitObserver { path, selected }))
            .is_ok()
    );
    crate::entrypoint::run().expect("natural observed server shutdown");
}
