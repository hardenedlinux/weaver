// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

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
    delivery_used: std::sync::atomic::AtomicBool,
}
static OBSERVER: OnceLock<Arc<CommitObserver>> = OnceLock::new();

impl Observer for CommitObserver {
    fn observe(&self, cut: Cut) -> Decision {
        if cut == Cut::AfterDeliveryCommit
            && matches!(
                self.selected,
                Cut::BeforeDeliveryCommit | Cut::AfterDeliveryCommit
            )
        {
            let mut published =
                UnixStream::connect(&self.path).expect("snapshot publication observer");
            published
                .set_write_timeout(Some(Duration::from_secs(3)))
                .expect("bounded publication observation");
            published
                .write_all(format!("SnapshotBurned {}\n", durable_delivery_marker()).as_bytes())
                .expect("known native prefix");
        }
        if cut != self.selected {
            return Decision::Continue;
        }
        if matches!(
            cut,
            Cut::BeforeDeliveryCommit
                | Cut::AfterDeliveryCommit
                | Cut::BeforeLifecycleCommit
                | Cut::AfterLifecycleCommit
                | Cut::BeforeAdmissionCommit
                | Cut::AfterAdmissionCommit
        ) && self
            .delivery_used
            .swap(true, std::sync::atomic::Ordering::SeqCst)
        {
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
        if matches!(cut, Cut::BeforeDeliveryCommit | Cut::AfterDeliveryCommit) {
            let mut manifest = UnixStream::connect(&self.path).expect("manifest observer");
            manifest
                .set_write_timeout(Some(Duration::from_secs(3)))
                .expect("bounded manifest observation");
            let prepared = delivery_manifest_marker();
            manifest
                .write_all(format!("PreparedRanges {prepared}\n").as_bytes())
                .expect("native manifest width");
        }
        let marker = match cut {
            Cut::BeforeRangePrepareCommit | Cut::AfterRangePrepareCommit => durable_range_marker(),
            Cut::BeforeDeliveryCommit | Cut::AfterDeliveryCommit => durable_delivery_marker(),
            Cut::BeforeLifecycleCommit | Cut::AfterLifecycleCommit => lifecycle_marker(),
            Cut::BeforeAdmissionCommit | Cut::AfterAdmissionCommit => admission_marker(),
            _ => durable_marker(),
        };
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
fn admission_marker() -> i64 {
    run_marker("SELECT COUNT(*) FROM provider_runs")
}
fn lifecycle_marker() -> i64 {
    run_marker("SELECT COUNT(*) FROM provider_runs WHERE state!='queued'")
}
fn run_marker(query: &str) -> i64 {
    let path = std::env::var("WEAVER_DB").expect("database");
    if !std::path::Path::new(&path).exists() {
        return 0;
    }
    let journal = if std::env::var("WEAVER_STORAGE_JOURNAL").as_deref() == Ok("mvcc") {
        persistence::Journal::Mvcc
    } else {
        persistence::Journal::Wal
    };
    let session = persistence::Session::open_with_journal(path, journal)
        .expect("independent lifecycle reader");
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
    persistence::one(&session, query, (), |r| r.get(0)).expect("committed native state")
}
fn durable_range_marker() -> i64 {
    if durable_marker() == 0 {
        return 0;
    }
    let path = std::env::var("WEAVER_DB").expect("fixture database");
    let session = persistence::Session::open_with_journal(path, persistence::Journal::Mvcc)
        .expect("independent MVCC reader");
    persistence::one(
        &session,
        "SELECT CASE WHEN COUNT(*)=(SELECT COALESCE(MAX(next_event),0) FROM provider_runs)
                THEN COUNT(*) ELSE -1 END FROM provider_releases WHERE state='unknown'",
        (),
        |row| row.get(0),
    )
    .expect("atomic pending range group and cursor")
}

fn delivery_manifest_marker() -> i64 {
    let journal = if std::env::var("WEAVER_STORAGE_JOURNAL").as_deref() == Ok("mvcc") {
        persistence::Journal::Mvcc
    } else {
        persistence::Journal::Wal
    };
    let session = persistence::Session::open_with_journal(
        std::env::var("WEAVER_DB").expect("fixture database"),
        journal,
    )
    .expect("independent manifest reader");
    persistence::one(
        &session,
        "SELECT COUNT(*) FROM provider_releases",
        (),
        |row| row.get(0),
    )
    .expect("durable prepared manifest")
}

fn durable_delivery_marker() -> i64 {
    if durable_marker() == 0 {
        return 0;
    }
    let journal = if std::env::var("WEAVER_STORAGE_JOURNAL").as_deref() == Ok("mvcc") {
        persistence::Journal::Mvcc
    } else {
        persistence::Journal::Wal
    };
    let session = persistence::Session::open_with_journal(
        std::env::var("WEAVER_DB").expect("fixture database"),
        journal,
    )
    .expect("independent delivery reader");
    persistence::one(
        &session,
        "SELECT COUNT(*) FROM provider_releases WHERE state='released'",
        (),
        |row| row.get(0),
    )
    .expect("durable released ranges")
}
fn durable_marker() -> i64 {
    run_marker("SELECT COALESCE(MAX(dispatched),0) FROM provider_runs")
}
pub(crate) fn mutation_started(operation: &str, phase: &str) {
    if operation == "racing-a"
        && let Some(observer) = OBSERVER.get()
    {
        let mut socket = UnixStream::connect(&observer.path).expect("private mutation observer");
        socket
            .set_write_timeout(Some(Duration::from_secs(3)))
            .expect("bounded observation");
        socket
            .write_all(format!("{phase} 0\n").as_bytes())
            .expect("source worker entered");
    }
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
        Ok("prepare-before") => Cut::BeforeRangePrepareCommit,
        Ok("prepare-after") => Cut::AfterRangePrepareCommit,
        Ok("lifecycle-before") => Cut::BeforeLifecycleCommit,
        Ok("lifecycle-after") => Cut::AfterLifecycleCommit,
        Ok("admission-before") => Cut::BeforeAdmissionCommit,
        Ok("admission-after") => Cut::AfterAdmissionCommit,
        Ok("delivery-before") => Cut::BeforeDeliveryCommit,
        Ok("delivery-after") => Cut::AfterDeliveryCommit,
        _ => panic!("explicit commit cut required"),
    };
    // Restart reads the recovered store before any provider RPC can modify it.
    let mut socket = UnixStream::connect(&path).expect("startup observer");
    socket
        .write_all(
            format!(
                "Boot {}\n",
                match selected {
                    Cut::BeforeRangePrepareCommit | Cut::AfterRangePrepareCommit =>
                        durable_range_marker(),
                    Cut::BeforeDeliveryCommit | Cut::AfterDeliveryCommit =>
                        durable_delivery_marker(),
                    Cut::BeforeLifecycleCommit | Cut::AfterLifecycleCommit => lifecycle_marker(),
                    Cut::BeforeAdmissionCommit | Cut::AfterAdmissionCommit => admission_marker(),
                    _ => durable_marker(),
                }
            )
            .as_bytes(),
        )
        .expect("recovery observation");
    assert!(
        OBSERVER
            .set(Arc::new(CommitObserver {
                path,
                selected,
                delivery_used: std::sync::atomic::AtomicBool::new(false)
            }))
            .is_ok()
    );
    crate::entrypoint::run().expect("natural observed server shutdown");
}
