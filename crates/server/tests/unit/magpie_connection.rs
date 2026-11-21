// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{ConnectionControl, ConnectionOutcome};
use crate::{HttpProfile, ServiceRuntime};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn control_recovers_exact_intent_and_keeps_foreign_namespaces_separate() {
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        let dir = tempfile::tempdir().expect("connection configuration fixture");
        let database = dir.path().join("control.db");
        let runtime = ServiceRuntime::new();
        let a = ConnectionControl::new(database.clone(), "a", runtime.clone())
            .expect("connection configuration fixture");
        let b = ConnectionControl::new(database.clone(), "b", runtime.clone())
            .expect("connection configuration fixture");
        let profile = HttpProfile {
            session: "session".into(),
            token_sha256: [1; 32],
        };
        let key = a
            .prepare(
                "original".try_into().expect("operation id"),
                None,
                Some(profile.clone()),
            )
            .await
            .expect("connection configuration fixture");
        assert_eq!(
            a.current().await.expect("connection configuration fixture"),
            None
        );
        assert_eq!(
            a.receipt(key.clone())
                .await
                .expect("connection configuration fixture"),
            None
        );
        assert!(b.publish(key.clone()).await.is_err());
        let restarted = ConnectionControl::new(database.clone(), "a", runtime.clone())
            .expect("connection configuration fixture");
        assert_eq!(
            restarted
                .prepare(
                    "original".try_into().expect("operation id"),
                    None,
                    Some(profile.clone())
                )
                .await
                .expect("connection configuration fixture"),
            key
        );
        let receipt = restarted
            .publish(key.clone())
            .await
            .expect("connection configuration fixture");
        assert_eq!(receipt.outcome, ConnectionOutcome::Committed);
        let lease = tokio::task::spawn_blocking(move || {
            let mut ledger =
                weaver_ledger::Ledger::open(database).expect("connection configuration fixture");
            ledger
                .lease_connection(
                    &HttpProfile::connection_id("a").expect("connection configuration fixture"),
                )
                .expect("connection configuration fixture")
        })
        .await
        .expect("connection configuration fixture");
        let retiring = a
            .prepare("retire".try_into().expect("operation id"), Some(0), None)
            .await
            .expect("connection configuration fixture");
        assert!(a.publish(retiring.clone()).await.is_err());
        assert_eq!(
            a.receipt(retiring.clone())
                .await
                .expect("connection configuration fixture"),
            None
        );
        drop(lease);
        a.publish(retiring)
            .await
            .expect("connection configuration fixture");
        assert_eq!(
            a.publish(key)
                .await
                .expect("connection configuration fixture"),
            receipt
        );
        let head = a
            .current()
            .await
            .expect("connection configuration fixture")
            .expect("connection configuration fixture");
        assert_eq!(head.revision, 1);
        assert_eq!(head.profile, None);
        runtime.request_shutdown();
        runtime.drain().await;
    })
    .await
    .expect("connection configuration fixture");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn aborted_intent_stays_aborted_and_closed_runtime_refuses_control() {
    let dir = tempfile::tempdir().expect("connection configuration fixture");
    let runtime = ServiceRuntime::new();
    let control = ConnectionControl::new(dir.path().join("control.db"), "a", runtime.clone())
        .expect("connection configuration fixture");
    let key = control
        .prepare(
            "abandon".try_into().expect("operation id"),
            None,
            Some(HttpProfile {
                session: "session".into(),
                token_sha256: [1; 32],
            }),
        )
        .await
        .expect("connection configuration fixture");
    assert_eq!(
        control
            .abort(key.clone())
            .await
            .expect("connection configuration fixture")
            .outcome,
        ConnectionOutcome::Aborted
    );
    assert_eq!(
        control
            .publish(key)
            .await
            .expect("connection configuration fixture")
            .outcome,
        ConnectionOutcome::Aborted
    );
    assert!(
        control
            .current()
            .await
            .expect("connection configuration fixture")
            .is_none()
    );
    runtime.request_shutdown();
    assert!(control.current().await.is_err());
    runtime.drain().await;
}
