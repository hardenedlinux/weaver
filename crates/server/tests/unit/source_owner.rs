// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{SourceOwner, answer};
use crate::runtime::RuntimeOwner;
use crate::test_fixtures as fixtures;
use std::{sync::Arc, time::Duration};
use tokio::sync::{Semaphore, oneshot};
use weaver_contracts::{Publication, PublicationKey, PublicationOutcome};
use weaver_ledger::Ledger;
fn caller() -> weaver_contracts::SourceIdentity {
    weaver_contracts::SourceIdentity {
        certificate_sha256: weaver_contracts::body_digest("source certificate"),
        public_key_sha256: weaver_contracts::body_digest("source SPKI"),
        credential_sha256: weaver_contracts::body_digest("source credential"),
    }
}

const POLICY: &str = include_str!("../../../../prod/policies/provider/provider.cedar");
const SCHEMA: &str = include_str!("../../../../prod/policies/provider/schema.json");
fn change(id: &str, parent: Option<u64>) -> Publication {
    Publication {
        operation_id: id.into(),
        expected_revision: parent,
        fence: 1,
        policy: POLICY.into(),
        schema: SCHEMA.into(),
    }
}
fn slot() -> Arc<tokio::sync::OwnedSemaphorePermit> {
    Arc::new(
        Arc::new(Semaphore::new(1))
            .try_acquire_owned()
            .expect("slot"),
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn reused_source_connection_observes_other_writer_and_preserves_historical_result() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("source.db");
    let runtime = RuntimeOwner::new();
    let worker = SourceOwner::start(runtime.clone(), slot(), path.clone())
        .await
        .expect("start");
    let owner = worker.client.clone();
    let original = change("original", None);
    let receipt = owner
        .publish(caller(), original.clone())
        .await
        .expect("commit");
    let mut other = Ledger::open(&path).expect("other owner");
    assert_eq!(
        other
            .publish_typed(Some(0), POLICY, SCHEMA, 2)
            .expect("external publication"),
        1
    );
    let stale = owner
        .publish(caller(), change("stale", Some(0)))
        .await
        .expect("decision");
    assert_eq!(stale.outcome, PublicationOutcome::Rejected);
    assert_eq!(stale.revision, Some(1));
    assert_eq!(stale.fence, Some(2));
    let observed = owner
        .inspect(
            caller(),
            PublicationKey {
                operation_id: original.operation_id.clone(),
                digest: original.digest().expect("digest"),
            },
        )
        .await
        .expect("query");
    assert_eq!(observed, Some(receipt.clone()));
    assert_eq!(
        owner.publish(caller(), original).await.expect("replay"),
        receipt
    );
    runtime.drain().await;
    worker.finish().await.expect("successful source close");
    assert!(
        owner
            .publish(caller(), change("after-close", Some(1)))
            .await
            .is_err()
    );
    let reopened = Ledger::open(&path).expect("reopen");
    reopened
        .require_quiescent()
        .expect("closed source transaction");
}

#[tokio::test]
async fn storage_failure_does_not_acknowledge_a_reusable_result() {
    let directory = tempfile::tempdir().expect("directory");
    let ledger = Ledger::open(directory.path().join("source.db")).expect("ledger");
    let (reply, receiver) = oneshot::channel();
    assert!(
        answer(
            &ledger,
            reply,
            Err::<(), _>(weaver_contracts::Error::Storage("injected failure".into())),
            Arc::new(Semaphore::new(1))
                .try_acquire_owned()
                .expect("command slot"),
        )
        .is_err()
    );
    assert!(receiver.await.is_err());
}

#[tokio::test]
async fn completed_source_acknowledgment_returns_command_capacity() {
    let directory = tempfile::tempdir().expect("directory");
    let ledger = Ledger::open(directory.path().join("source.db")).expect("ledger");
    let capacity = Arc::new(Semaphore::new(1));
    for result in [Ok(()), Err(weaver_contracts::Error::Conflict("rejected"))] {
        let slot = capacity.clone().try_acquire_owned().expect("slot");
        let (reply, receiver) = oneshot::channel();
        assert_eq!(capacity.available_permits(), 0);
        answer(&ledger, reply, result, slot).expect("quiescent decision");
        let _decision = receiver.await.expect("acknowledgment");
        assert_eq!(capacity.available_permits(), 1);
    }
}

#[tokio::test]
async fn startup_failure_closes_runtime_and_drains_source_owner() {
    let directory = tempfile::tempdir().expect("directory");
    let runtime = RuntimeOwner::new();
    assert!(
        SourceOwner::start(runtime.clone(), slot(), directory.path().to_path_buf())
            .await
            .is_err()
    );
    tokio::time::timeout(Duration::from_secs(3), runtime.drain())
        .await
        .expect("drain");
    assert!(runtime.closing());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn disconnected_source_caller_keeps_capacity_until_original_sql_work_finishes() {
    use std::{collections::BTreeSet, future::Future, task::Poll};
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("source.db");
    let runtime = RuntimeOwner::new();
    let worker = SourceOwner::start(runtime.clone(), slot(), path.clone())
        .await
        .expect("start");
    let owner = worker.client.clone();
    owner
        .publish(caller(), change("bootstrap", None))
        .await
        .expect("bootstrap");
    let (task, plan) = fixtures::task_plan(16, "https://provider.invalid/v1/chat/completions");
    owner.register(caller(), task, None).await.expect("task");
    let mut writer = Ledger::open(&path).expect("writer");
    writer.enqueue_provider(&plan).expect("queue");
    let permit = writer
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    let (entered, started) = oneshot::channel();
    let (release, blocked) = std::sync::mpsc::channel();
    let writing = std::thread::spawn(move || {
        writer
            .dispatch_provider(&permit, || {
                let _ = entered.send(());
                blocked
                    .recv_timeout(Duration::from_secs(3))
                    .expect("release writer");
                Ok(())
            })
            .expect("guarded writer")
    });
    started.await.expect("writer entered");
    let proposal = change("original", Some(0));
    let mut publishing = Box::pin(owner.publish(caller(), proposal.clone()));
    std::future::poll_fn(|cx| {
        assert!(matches!(publishing.as_mut().poll(cx), Poll::Pending));
        Poll::Ready(())
    })
    .await;
    drop(publishing);
    let key = PublicationKey {
        operation_id: proposal.operation_id.clone(),
        digest: proposal.digest().expect("digest"),
    };
    assert_eq!(
        owner
            .inspect(caller(), key.clone())
            .await
            .expect_err("capacity still occupied")
            .code(),
        tonic::Code::ResourceExhausted
    );
    release.send(()).expect("release");
    writing.join().expect("writer completed");
    let result = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            match owner.inspect(caller(), key.clone()).await {
                Err(error) if error.code() == tonic::Code::ResourceExhausted => {
                    tokio::time::sleep(Duration::from_millis(1)).await
                }
                result => break result,
            }
        }
    })
    .await
    .expect("decision deadline")
    .expect("query")
    .expect("original decision");
    assert_eq!(result.outcome, PublicationOutcome::Committed);
    assert_eq!(result.revision, Some(1));
    runtime.drain().await;
    worker.finish().await.expect("source close");
    assert_eq!(
        Ledger::open(path)
            .expect("recover")
            .held("f")
            .expect("held"),
        4
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn review_context_uses_provisioned_metadata_and_does_not_publish() {
    let directory = tempfile::tempdir().expect("dir");
    let path = directory.path().join("review.db");
    let mut ledger = Ledger::open(&path).expect("store");
    ledger
        .install_review_authority(&weaver_contracts::ReviewAuthority {
            audience: "test-gateway".into(),
            epoch: 0,
            public_key: "4".repeat(64),
            allow_expansion: false,
            qualified_catalog: None,
        })
        .expect("native provision");
    drop(ledger);
    let runtime = RuntimeOwner::new();
    let worker = SourceOwner::start(runtime.clone(), slot(), path.clone())
        .await
        .expect("start");
    let p = change("reviewed", None);
    let key = worker
        .client
        .stage_reviewed(caller(), p)
        .await
        .expect("stage");
    let context = worker
        .client
        .review_context(caller(), key.clone())
        .await
        .expect("owned context");
    assert_eq!(context.parent, None);
    assert_eq!(context.publication, key);
    assert_eq!(context.reviewer.audience, "test-gateway");
    assert_eq!(context.source.identity, caller());
    assert_eq!(
        worker.client.inspect(caller(), key).await.expect("observe"),
        None
    );
    runtime.drain().await;
    worker.finish().await.expect("natural drain");
}
