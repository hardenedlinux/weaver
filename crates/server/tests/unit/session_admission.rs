// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{runtime::RuntimeOwner, source_owner::SourceOwner};
use std::{num::NonZeroUsize, sync::Arc, time::Duration};
use tokio::sync::Semaphore;
use weaver_contracts::{
    FactFeed, FactIntent, ProviderSessionScope, SourceAuthority, SourceIdentity, body_digest,
};

fn slot() -> Arc<tokio::sync::OwnedSemaphorePermit> {
    Arc::new(Arc::new(Semaphore::new(1)).try_acquire_owned().unwrap())
}
fn caller() -> SourceIdentity {
    SourceIdentity {
        certificate_sha256: body_digest("cert"),
        public_key_sha256: body_digest("key"),
        credential_sha256: body_digest("credential"),
    }
}
fn request(key: &str, count: usize) -> weaver_ledger::ProviderSessionRequest {
    weaver_ledger::ProviderSessionRequest {session:"session-a".into(),principal:"alice".into(),submission:weaver_contracts::ProviderTurnSubmission {
        operation_id:key.into(),body:serde_json::json!({"model":"model-a","stream":true,"max_tokens":32,
            "messages":(0..count).map(|_|serde_json::json!({"role":"user","content":key})).collect::<Vec<_>>()}).to_string()}}
}
async fn change(owner: &SourceOwner, available: bool) {
    let state = owner.inspect_fact(caller()).await.unwrap();
    let barrier = owner
        .stage_fact(
            caller(),
            FactIntent {
                operation_id: format!("fact-{}", state.revision + 1),
                domain: state.domain,
                source_epoch: state.source_epoch,
                revision: state.revision + 1,
                previous_snapshot: state.snapshot,
                expected_floor: state.floor,
                available,
            },
        )
        .await
        .unwrap();
    let weaver_ledger::FactPreparation::Pending(work) =
        owner.prepare_fact(caller(), barrier).await.unwrap()
    else {
        panic!("pending");
    };
    owner
        .resolve_fact(caller(), work, vec!["infer".into()])
        .await
        .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn source_lane_rejoins_after_advisory_work_and_does_not_hold_sql_across_the_owner() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("session.db");
    let runtime = RuntimeOwner::new();
    runtime
        .install_fact_feed(FactFeed {
            domain: "facts".into(),
            authority: SourceAuthority {
                epoch: 0,
                identity: caller(),
            },
            family: "session-a".into(),
            root: "infer".into(),
            dependencies: vec![],
            workflow: None,
            workflow_path: vec![],
            workflow_dag: false,
            workflow_choice: false,
            workflow_selectors: vec![],
        })
        .unwrap();
    let worker = SourceOwner::start(runtime.clone(), slot(), path.clone())
        .await
        .unwrap();
    let source = worker.client.clone();
    let publication = weaver_contracts::Publication {
        operation_id: "session-pub".into(),
        expected_revision: None,
        fence: 1,
        policy: include_str!("../../../../prod/policies/provider/provider.cedar")
            .replace("context.family == \"f\"", "context.family like \"turn:*\"")
            .replace("openai.chat-text-sse.v1", "openai.chat-turn-sse.v1"),
        schema: include_str!("../../../../prod/policies/provider/schema.json").into(),
    };
    source.publish(caller(), publication.clone()).await.unwrap();
    let scope:ProviderSessionScope=weaver_contracts::decode(serde_json::json!({"template":{"family":"session-a","principal":"alice","profile":"p",
        "provider_profile":{"id":"p","protocol":"openai.chat-turn-sse.v1","max_output_tokens":32,"max_messages":8,"max_body_bytes":4096},
        "nodes":["infer"],"targets":["primary"],"endpoints":{"primary":"https://provider.invalid/v1/chat/completions"},"body_digests":{},"stream_contracts":{},"node_cost_bounds":{"infer":4},"models":["model-a"],"budget":8},
        "domains":{"origin":"session-a","budget":"shared","history":"history","budget_limit":8},"max_turns":4,
        "publication":{"operation_id":publication.operation_id,"digest":publication.digest().unwrap()}}).to_string().as_bytes()).unwrap();
    source.register_session(caller(), scope).await.unwrap();
    change(&source, true).await;
    let catalog = source
        .operation_resolver()
        .session_catalog("session-a".into(), "alice".into())
        .await
        .unwrap();
    assert_eq!(catalog.models, vec!["model-a"]);
    assert!(
        source
            .operation_resolver()
            .session_catalog("session-a".into(), "other".into())
            .await
            .is_err()
    );
    let (client, inbox) = weaver_governance::source_lane(NonZeroUsize::new(4).unwrap());
    runtime.attach_governance(client).unwrap();
    let (entered, waiting) = std::sync::mpsc::channel();
    let (release, resume) = std::sync::mpsc::channel();
    let derivations = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let observed_derivations = derivations.clone();
    // This fake advisory owner qualifies actor/transaction wiring only, not Scheme.
    let semantic = runtime
        .spawn_blocking(slot(), move |_| {
            inbox.run_with_cancellable_governor(
                (),
                |_, _, _| panic!("no per-turn compilation"),
                |_, input| {
                    let weaver_governance::Derivation::SessionTurn(input) = input else {
                        return Err(weaver_governance::SourceError::Contract);
                    };
                    observed_derivations.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    if input.facts.message_count == 2 {
                        entered.send(()).unwrap();
                        resume.recv_timeout(Duration::from_secs(5)).unwrap();
                    }
                    Ok(weaver_governance::DerivationOutput::SessionTurn(
                        weaver_governance::SessionTurnSelection {
                            scope_commitment: input.scope.digest().unwrap(),
                            route_indices: vec![0],
                        },
                    ))
                },
            );
            Ok(())
        })
        .unwrap();
    let resolver = source.operation_resolver();
    let first = resolver
        .admit_turn(&runtime, request("first", 1))
        .await
        .unwrap();
    let second = resolver
        .admit_turn(&runtime, request("second", 1))
        .await
        .unwrap();
    assert_eq!(
        resolver
            .admit_turn(&runtime, request("first", 1))
            .await
            .unwrap(),
        first
    );
    assert_eq!(derivations.load(std::sync::atomic::Ordering::SeqCst), 2);
    assert!(
        source
            .operation_resolver()
            .admit_turn(&runtime, request("first", 2))
            .await
            .is_err(),
        "changed retry bytes must fail before advisory work"
    );
    assert_eq!(derivations.load(std::sync::atomic::Ordering::SeqCst), 2);
    let mut ledger = weaver_ledger::Ledger::open(&path).unwrap();
    ledger.enqueue_provider(&first.plan).unwrap();
    ledger.enqueue_provider(&second.plan).unwrap();
    assert_eq!(
        ledger.execution_domains(&first.task.family).unwrap().held,
        8
    );
    let task = {
        let runtime = runtime.clone();
        tokio::spawn(async move { resolver.admit_turn(&runtime, request("third", 2)).await })
    };
    tokio::task::spawn_blocking(move || waiting.recv_timeout(Duration::from_secs(5)).unwrap())
        .await
        .unwrap();
    assert_eq!(
        tokio::time::timeout(
            Duration::from_secs(3),
            source
                .operation_resolver()
                .admit_turn(&runtime, request("first", 1)),
        )
        .await
        .expect("exact replay must not queue behind advisory work")
        .unwrap(),
        first
    );
    let withdrawn = tokio::time::timeout(Duration::from_secs(3), change(&source, false)).await;
    release.send(()).unwrap();
    assert!(
        withdrawn.is_ok(),
        "advisory work must not retain SQL lane or writer"
    );
    assert!(
        source
            .operation_resolver()
            .session_catalog("session-a".into(), "alice".into())
            .await
            .is_err()
    );
    assert!(
        task.await.unwrap().is_err(),
        "changed facts invalidate the captured deciding cut"
    );
    assert!(
        source
            .operation_resolver()
            .admit_turn(&runtime, request("first", 1))
            .await
            .is_err(),
        "a retained decision cannot bypass withdrawn facts"
    );
    assert_eq!(derivations.load(std::sync::atomic::Ordering::SeqCst), 3);
    assert_eq!(
        ledger.execution_domains(&first.task.family).unwrap().held,
        8
    );
    runtime.drain().await;
    worker.finish().await.unwrap();
    semantic.await.unwrap().unwrap();
}
