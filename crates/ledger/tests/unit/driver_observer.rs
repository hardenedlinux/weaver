// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{DriverSpan, driver_dispatch, observe};
#[path = "../../../contracts/benches/support/fixtures.rs"]
mod provider_fixture;

#[test]
fn manifest_programs_rebind_current_members_and_reject_divergence() {
    use crate::persistence::{Journal, Session};
    driver_dispatch();
    for journal in [Journal::Wal, Journal::Mvcc] {
        let dir = tempfile::tempdir().expect("ledger directory");
        let path = dir.path().join("members.db");
        let storage = Session::open_with_journal(&path, journal).expect("journal");
        let mut ledger = crate::Ledger::open(&path).expect("ledger");
        ledger
            .publish_typed(
                None,
                include_str!("../../../../prod/policies/provider/provider.cedar"),
                include_str!("../../../../prod/policies/provider/schema.json"),
                1,
            )
            .expect("policy");
        let (task, plan) =
            provider_fixture::task_plan(8, "https://provider.invalid/v1/chat/completions");
        ledger.register_task(&task).expect("original task");
        let mut peer = task.clone();
        peer.family = "g".into();
        let mut peer_plan = plan.clone();
        peer_plan.family = peer.family.clone();
        peer.stream_contracts.insert(
            peer_plan.node.clone(),
            peer_plan.digest().expect("peer commitment"),
        );
        ledger.register_task(&peer).expect("peer original");
        ledger
            .enqueue_provider(&plan)
            .expect("native claim and hold");
        let scope = crate::persistence::begin(&mut ledger.connection).expect("deciding scope");
        let exposure = crate::task_origins::require_prepared(&scope, &task.family, None)
            .expect("original exposure");
        let expected = crate::exposure_manifest::verified_members(&scope, &task.family, &exposure)
            .expect("members");
        assert_eq!(expected.len(), 1);
        let (actual, warm, _) = observe(DriverSpan::Prepare, || {
            crate::exposure_manifest::verified_members(&scope, &task.family, &exposure)
        });
        assert_eq!(actual.expect("fresh current members"), expected);
        eprintln!(
            "manifest native preparations journal={journal:?} warm={} (one metering query, no manifest compilation)",
            warm.attempts
        );
        assert_eq!(warm.attempts, 1, "fixed manifest programs recompiled");
        let peer_exposure = crate::task_origins::require_prepared(&scope, &peer.family, None)
            .expect("peer exposure");
        assert!(
            crate::exposure_manifest::verified_members(&scope, &peer.family, &peer_exposure)
                .expect("fresh parameter binding")
                .is_empty()
        );
        crate::persistence::exec(
            &scope,
            "UPDATE provider_runs SET reserved=3 WHERE family='f'",
            (),
        )
        .expect("projection fault");
        assert!(
            crate::exposure_manifest::verified_members(&scope, &task.family, &exposure).is_err()
        );
        drop(scope);
        assert_eq!(
            ledger.held(&task.family).expect("original hold retained"),
            4
        );
        drop(storage);
    }
}

#[test]
fn review_program_reuse_preserves_native_receipts_and_currentness() {
    use crate::persistence::{Journal, Session};
    use crate::review_fixture::{change, evidence, issuer, source};
    driver_dispatch();
    for journal in [Journal::Wal, Journal::Mvcc] {
        let dir = tempfile::tempdir().expect("ledger directory");
        let path = dir.path().join("request.db");
        let storage = Session::open_with_journal(&path, journal).expect("journal");
        let mut ledger = crate::Ledger::open(&path).expect("ledger");
        ledger
            .install_review_authority(&issuer(0))
            .expect("reviewer");
        let mut publication = change("request", None);
        publication.policy =
            include_str!("../../../../prod/policies/provider/provider.cedar").into();
        let proof = evidence(&mut ledger, &publication);
        ledger
            .with_authenticated_source(&source(), |l| l.register_delta_review(&proof))
            .expect("review");
        let published = ledger
            .with_authenticated_source(&source(), |l| l.publish_authority(&publication))
            .expect("publication");
        let (task, plan) =
            provider_fixture::task_plan(8, "https://provider.invalid/v1/chat/completions");
        let key = weaver_contracts::PublicationKey {
            operation_id: published.operation_id,
            digest: published.digest,
        };
        ledger
            .register_published_task(&task, &key)
            .expect("published original task");
        crate::reviewed_head::prepare(&ledger.connection).expect("prepare review");
        ledger
            .enqueue_provider(&plan)
            .expect("native admission and receipt");
        let (candidate, after_enqueue, _) = observe(DriverSpan::Prepare, || {
            crate::reviewed_head::prepare(&ledger.connection)
        });
        candidate.expect("current review after admission");
        let permit = ledger
            .consume_provider(&plan.family, &plan.node, &["primary".into()].into())
            .expect("native consume");
        let (candidate, after_consume, _) = observe(DriverSpan::Prepare, || {
            crate::reviewed_head::prepare(&ledger.connection)
        });
        candidate.expect("current review after consumption");
        eprintln!(
            "review consumer preparations journal={journal:?} after_enqueue={} after_consume={}",
            after_enqueue.attempts, after_consume.attempts
        );
        assert_eq!(
            after_enqueue.attempts, 0,
            "admission/receipt invalidated the review program: {journal:?}"
        );
        assert_eq!(
            after_consume.attempts, 0,
            "consumption invalidated the review program: {journal:?}"
        );
        let candidate = crate::reviewed_head::prepare(&ledger.connection).expect("fresh candidate");
        let scope = crate::persistence::begin(&mut ledger.connection).expect("deciding scope");
        assert_eq!(
            candidate
                .current(&scope, plan.revision, plan.fence)
                .expect("exact current projection"),
            Some(publication.policy.as_str())
        );
        crate::persistence::exec(&scope, "UPDATE authority SET policy=policy||' '", ())
            .expect("projection fault");
        assert!(
            candidate
                .current(&scope, plan.revision, plan.fence)
                .is_err()
        );
        drop(scope);
        assert_eq!(permit.plan(), &plan);
        assert_eq!(ledger.held(&plan.family).expect("original hold"), 4);
        drop(storage);
    }
}

#[test]
fn review_program_reuse_reads_replacement_and_rejects_projection_loss() {
    use crate::review_fixture::{change, evidence, issuer, source};
    driver_dispatch();
    let dir = tempfile::tempdir().expect("ledger directory");
    let mut ledger = crate::Ledger::open(dir.path().join("review-program.db")).expect("ledger");
    ledger
        .install_review_authority(&issuer(0))
        .expect("reviewer");
    for (name, parent) in [("first", None), ("replacement", Some(0))] {
        let publication = change(name, parent);
        let proof = evidence(&mut ledger, &publication);
        ledger
            .with_authenticated_source(&source(), |l| l.register_delta_review(&proof))
            .expect("review");
        let receipt = ledger
            .with_authenticated_source(&source(), |l| l.publish_authority(&publication))
            .expect("publication");
        let (first, cold, _) = observe(DriverSpan::Prepare, || {
            crate::reviewed_head::prepare(&ledger.connection)
        });
        let first = first.expect("fresh projection");
        let (second, warm, _) = observe(DriverSpan::Prepare, || {
            crate::reviewed_head::prepare(&ledger.connection)
        });
        let second = second.expect("rebound projection");
        if parent.is_none() {
            eprintln!(
                "review native preparations cold={} warm={}",
                cold.attempts, warm.attempts
            );
            assert_eq!(warm.attempts, 0, "native program was recompiled");
        }
        let scope = crate::persistence::begin(&mut ledger.connection).expect("deciding scope");
        for candidate in [&first, &second] {
            assert_eq!(
                candidate
                    .current(
                        &scope,
                        receipt.revision.expect("revision"),
                        receipt.fence.expect("fence")
                    )
                    .expect("current projection"),
                Some(publication.policy.as_str())
            );
        }
    }
    crate::persistence::exec(&ledger.connection, "DELETE FROM review_authority", ())
        .expect("lose projection");
    assert!(
        crate::reviewed_head::prepare(&ledger.connection).is_err(),
        "cached SQL cannot retain authority"
    );
}

#[test]
fn prepared_singleton_finishes_and_rebinds_without_replaying_a_cursor() {
    let dir = tempfile::tempdir().expect("ledger directory");
    let session =
        crate::persistence::Session::open(dir.path().join("singleton.db")).expect("ledger");
    for value in [1_i64, 2] {
        assert_eq!(
            crate::persistence::maybe_prepared(&session, "SELECT ?1", [value], |row| row
                .get::<i64>(0))
            .expect("bound query"),
            Some(value)
        );
    }
    assert!(
        crate::persistence::maybe_prepared(&session, "SELECT 1 WHERE 0", (), |row| row
            .get::<i64>(0))
        .expect("empty query")
        .is_none()
    );
    assert!(
        crate::persistence::maybe_prepared(&session, "SELECT 1 UNION ALL SELECT 2", (), |row| row
            .get::<i64>(
            0
        ))
        .is_err()
    );
}

#[cfg(unix)]
#[test]
fn commit_io_observes_native_spans_after_unobserved_setup() {
    driver_dispatch();
    let dir = tempfile::tempdir().expect("ledger directory");
    let session =
        crate::persistence::Session::open(dir.path().join("commit-io.db")).expect("ledger");
    crate::persistence::script(&session, "CREATE TABLE observed_io(value INTEGER)")
        .expect("schema");
    let tx = futures_executor::block_on(
        crate::persistence::driver::transaction::Transaction::new_unchecked(
            &session,
            crate::persistence::driver::transaction::TransactionBehavior::Immediate,
        ),
    )
    .expect("transaction");
    crate::persistence::exec(&tx, "INSERT INTO observed_io VALUES(1)", ()).expect("write");
    let (result, sync, io) =
        super::observe_commit(true, || futures_executor::block_on(tx.commit()));
    result.expect("commit");
    let io = io.expect("I/O observation");
    assert!(io.rows[0][0] > 0);
    assert!(io.rows[2][2] + io.rows[3][2] > 0, "missing native writes");
    assert!(sync.attempts > 0, "missing native sync");
    assert_eq!(io.rows[4][2], sync.attempts);
    assert!(io.rows[4][0] <= io.rows[0][0]);
    let (_, _, disabled) = super::observe_commit(false, || {});
    assert!(disabled.is_none());
}

#[test]
fn prepare_first_seen_outside_scoped_dispatch_is_still_observed() {
    driver_dispatch();
    // Open issues Turso statements before the observer is active on this thread.
    let dir = tempfile::tempdir().expect("ledger directory");
    let session =
        crate::persistence::Session::open(dir.path().join("observer.db")).expect("open ledger");
    let (statement, wall, _) = observe(DriverSpan::Prepare, || {
        futures_executor::block_on(session.prepare("BEGIN IMMEDIATE"))
    });
    assert!(statement.is_ok());
    assert_eq!(wall.attempts, 1, "missing Turso prepare span");
}
