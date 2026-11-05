// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Positive native concurrency, not a scheduler-only or mocked SQL acceptance.
use super::fixture_nodes;
use std::{
    collections::BTreeSet,
    sync::{Arc, Mutex, mpsc},
    thread,
    time::Duration,
};
use weaver_contracts::{DomainBinding, Task};
use weaver_ledger::{
    Ledger,
    persistence::{
        self, Journal, Session,
        commit_observer::{Cut, Decision, Observer},
    },
};

struct Pause {
    arrived: mpsc::Sender<()>,
    resume: Mutex<mpsc::Receiver<()>>,
}
impl Observer for Pause {
    fn observe(&self, cut: Cut) -> Decision {
        if cut == Cut::BeforeRangePrepareCommit {
            self.arrived
                .send(())
                .expect("native prepare reached commit");
            self.resume
                .lock()
                .expect("resume")
                .recv()
                .expect("release native commit");
        }
        Decision::Continue
    }
}

#[test]
fn shared_reads_keep_distinct_origin_native_writes_concurrent() {
    let directory = tempfile::tempdir().expect("store");
    let path = directory.path().join("shared-read.db");
    let storage = Session::open_with_journal(&path, Journal::Mvcc).expect("MVCC");
    let (mut ledger, mut plan) = fixture_nodes(&path, &["infer"]);
    let policy = super::POLICY.replace(
        "context.family == \"f\"",
        "[\"f\",\"peer\"].contains(context.family)",
    );
    ledger
        .publish_typed(Some(0), &policy, super::SCHEMA, 2)
        .expect("peer Policy");
    plan.revision = 1;
    plan.fence = 2;
    let mut peer = plan.clone();
    peer.family = "peer".into();
    let record: String = persistence::one(
        &storage,
        "SELECT record FROM tasks WHERE family='f'",
        (),
        |r| r.get(0),
    )
    .expect("original");
    let mut task: Task = serde_json::from_str(&record).expect("typed");
    task.family = peer.family.clone();
    task.stream_contracts
        .insert(peer.node.clone(), peer.digest().expect("peer contract"));
    ledger
        .register_task_domains(
            &task,
            &DomainBinding {
                origin: "peer-origin".into(),
                budget: "f".into(),
                history: "f".into(),
                budget_limit: 8,
            },
            None,
        )
        .expect("shared constraints");
    for plan in [&plan, &peer] {
        ledger.enqueue_provider(plan).expect("reserve");
    }
    let targets = BTreeSet::from(["primary".into()]);
    let mut workers = Vec::new();
    for family in ["f", "peer"] {
        let mut worker = Ledger::open(&path).expect("independent session");
        let permit = worker
            .consume_provider(family, "infer", &targets)
            .expect("consume on deciding session");
        worker
            .dispatch_provider(&permit, || Ok(()))
            .expect("one request per origin");
        workers.push((worker, permit));
    }
    let (arrived, observed) = mpsc::channel();
    thread::scope(|threads| {
        let mut releases = Vec::new();
        let mut jobs = Vec::new();
        for (mut worker, permit) in workers {
            let (resume, receiver) = mpsc::channel();
            releases.push(resume);
            let observer = Arc::new(Pause {
                arrived: arrived.clone(),
                resume: Mutex::new(receiver),
            });
            jobs.push(threads.spawn(move || {
                worker.observe_provider_commit(observer);
                worker.prepare_provider_releases(&permit, &[("one", 1), ("two", 1)], "protobuf")
            }));
        }
        let first = observed.recv_timeout(Duration::from_secs(3));
        let second = observed.recv_timeout(Duration::from_secs(3));
        for release in releases {
            let _ = release.send(());
        }
        let outcomes: Vec<_> = jobs
            .into_iter()
            .map(|job| job.join().expect("worker"))
            .collect();
        let errors: Vec<_> = outcomes.iter().map(|o| o.as_ref().err()).collect();
        assert!(
            first.is_ok() && second.is_ok(),
            "both native writers must coexist before commit: {first:?}, {second:?}; {errors:?}"
        );
        for outcome in outcomes {
            assert_eq!(outcome.expect("independent native commit").len(), 2);
        }
    });
    assert_eq!(
        ledger.execution_domains("f").expect("actual budget").held,
        8
    );
    assert_eq!(
        ledger
            .execution_domains("f")
            .expect("actual history")
            .history_count,
        2
    );
    let rows: i64 = persistence::one(
        &storage,
        "SELECT COUNT(*) FROM provider_releases",
        (),
        |r| r.get(0),
    )
    .expect("all committed");
    assert_eq!(rows, 4);
}
