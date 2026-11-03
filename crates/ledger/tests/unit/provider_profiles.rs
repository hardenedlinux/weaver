#[path = "../../../contracts/benches/support/fixtures.rs"]
mod fixtures;

use std::{
    collections::BTreeSet,
    sync::{Arc, Barrier},
};
use weaver_contracts::{ProviderPlan, ProviderState, Task};
use weaver_ledger::Ledger;
use weaver_ledger::persistence::Session;

fn source(path: &std::path::Path) -> (Ledger, Task, ProviderPlan) {
    let (task, plan) = fixtures::task_plan(8, "https://provider.invalid/v1/chat/completions");
    let mut ledger = Ledger::open(path).expect("ledger");
    ledger
        .publish_typed(
            None,
            include_str!("../../../../prod/policies/provider/provider.cedar"),
            include_str!("../../../../prod/policies/provider/schema.json"),
            1,
        )
        .expect("source policy");
    ledger
        .register_task(&task)
        .expect("source task and profile");
    (ledger, task, plan)
}

#[test]
fn lost_registration_reply_recovers_one_profile_and_original_hold() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("profile.db");
    let (mut ledger, task, plan) = source(&path);
    ledger.enqueue_provider(&plan).expect("hold");
    drop(ledger); // The publisher did not receive its original registration acknowledgment.
    let mut restarted = Ledger::open(&path).expect("restart");
    restarted
        .register_task(&task)
        .expect("exact registration recovery");
    assert_eq!(restarted.held(&task.family).expect("hold"), 4);
    let connection = Session::open(&path).expect("observation");
    assert_eq!(
        weaver_ledger::persistence::one(
            &connection,
            "SELECT count(*) FROM provider_profiles",
            (),
            |r| r.get::<i64>(0)
        )
        .expect("profiles"),
        1
    );
    assert_eq!(
        weaver_ledger::persistence::one(&connection, "SELECT count(*) FROM tasks", (), |r| r
            .get::<i64>(0))
        .expect("tasks"),
        1
    );
}

#[test]
fn original_task_floor_prevents_missing_registry_from_rebinding_identity() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("profile.db");
    let (mut ledger, original, plan) = source(&path);
    ledger.enqueue_provider(&plan).expect("original hold");
    let observation = Session::open(&path).expect("fault injector");
    weaver_ledger::persistence::exec(&observation, "DELETE FROM provider_profiles", ())
        .expect("lost registry projection");
    let mut forged = original.clone();
    forged.family = "another-family".into();
    forged
        .provider_profile
        .as_mut()
        .expect("profile")
        .max_output_tokens = 64;
    let mut proposed = plan.clone();
    proposed.family = forged.family.clone();
    proposed.profile_commitment = forged
        .provider_profile
        .as_ref()
        .expect("profile")
        .digest()
        .expect("profile digest");
    forged.stream_contracts.insert(
        proposed.node.clone(),
        proposed.digest().expect("plan digest"),
    );
    assert!(
        ledger.register_task(&forged).is_err(),
        "missing registry erased original semantic floor"
    );
    assert_eq!(
        weaver_ledger::persistence::one(
            &observation,
            "SELECT count(*) FROM provider_profiles",
            (),
            |row| row.get::<i64>(0)
        )
        .expect("profiles"),
        0
    );
    ledger
        .register_task(&original)
        .expect("recover exact original artifact");
    assert_eq!(ledger.held("f").expect("hold"), 4);
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("original continuation");
    let mut calls = 0;
    ledger
        .dispatch_provider(&permit, || {
            calls += 1;
            Ok(())
        })
        .expect("same claim dispatch");
    assert_eq!(calls, 1);
    assert_eq!(ledger.held("f").expect("hold"), 4);
}

#[test]
fn metadata_key_order_does_not_reinterpret_the_original_profile() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("profile.db");
    let (mut ledger, task, plan) = source(&path);
    ledger.enqueue_provider(&plan).expect("original hold");
    let observation = Session::open(&path).expect("recovery projection");
    let record: String = weaver_ledger::persistence::one(
        &observation,
        "SELECT record FROM tasks WHERE family='f'",
        (),
        |r| r.get(0),
    )
    .expect("task");
    let profile_record: String = weaver_ledger::persistence::one(
        &observation,
        "SELECT record FROM provider_profiles WHERE id='p'",
        (),
        |r| r.get(0),
    )
    .expect("profile");
    let profile_fields: std::collections::BTreeMap<String, serde_json::Value> =
        serde_json::from_str(&profile_record).expect("profile fields");
    let reordered_profile = serde_json::to_string(&profile_fields).expect("metadata");
    let mut fields: std::collections::BTreeMap<String, serde_json::Value> =
        serde_json::from_str(&record).expect("task fields");
    fields.insert(
        "provider_profile".into(),
        serde_json::from_str(&reordered_profile).expect("profile value"),
    );
    let reordered_task = serde_json::to_string(&fields).expect("task metadata");
    assert_ne!(record, reordered_task);
    assert_ne!(profile_record, reordered_profile);
    weaver_ledger::persistence::exec(
        &observation,
        "UPDATE tasks SET record=?1 WHERE family='f'",
        weaver_ledger::persistence::params![(reordered_task).to_owned()],
    )
    .expect("restore task metadata");
    weaver_ledger::persistence::exec(
        &observation,
        "UPDATE provider_profiles SET record=?1 WHERE id='p'",
        weaver_ledger::persistence::params![(reordered_profile).to_owned()],
    )
    .expect("restore profile metadata");
    drop(ledger);
    let mut recovered = Ledger::open(&path).expect("restart");
    recovered
        .register_task(&task)
        .expect("same typed original registration");
    assert_eq!(recovered.held("f").expect("hold"), 4);
    let permit = recovered
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("original consume");
    let mut calls = 0;
    recovered
        .dispatch_provider(&permit, || {
            calls += 1;
            Ok(())
        })
        .expect("original dispatch");
    assert_eq!(calls, 1);
    assert_eq!(recovered.held("f").expect("hold"), 4);
}

#[test]
fn unknown_null_profile_field_cannot_hide_behind_cached_facts() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("profile.db");
    let (mut ledger, _, plan) = source(&path);
    ledger.enqueue_provider(&plan).expect("hold");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    let connection = Session::open(&path).expect("inconsistent image");
    let record: String = weaver_ledger::persistence::one(
        &connection,
        "SELECT record FROM tasks WHERE family='f'",
        (),
        |r| r.get(0),
    )
    .expect("record");
    let mut value: serde_json::Value = serde_json::from_str(&record).expect("task");
    value["provider_profile"]["scope"] = serde_json::Value::Null;
    weaver_ledger::persistence::exec(
        &connection,
        "UPDATE tasks SET record=?1 WHERE family='f'",
        weaver_ledger::persistence::params![
            (serde_json::to_string(&value).expect("image")).to_owned()
        ],
    )
    .expect("restore unknown field");
    let mut calls = 0;
    assert!(
        ledger
            .dispatch_provider(&permit, || {
                calls += 1;
                Ok(())
            })
            .is_err()
    );
    assert_eq!(calls, 0);
    assert_eq!(ledger.held("f").expect("hold"), 4);
}

#[test]
fn provider_profile_cannot_fall_back_to_untyped_request_or_raw_stream() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("profile.db");
    let (mut task, plan) = fixtures::task_plan(8, "https://provider.invalid/v1/chat/completions");
    let body = r#"{"model":"model-a","stream":false}"#;
    task.body_digests
        .insert(plan.node.clone(), weaver_contracts::body_digest(body));
    let raw = weaver_contracts::StreamContract {
        family: plan.family.clone(),
        node: plan.node.clone(),
        profile: plan.profile.clone(),
        target: plan.routes[0].target.clone(),
        input_digest: weaver_contracts::body_digest(body),
        destination: plan.routes[0].endpoint.clone(),
        messages: vec![weaver_contracts::MessageRule {
            id: "message".into(),
            max_bytes: 8,
            cost_bound: 4,
        }],
    };
    task.stream_contracts
        .insert(plan.node.clone(), raw.digest().expect("raw manifest"));
    let request = weaver_contracts::Proposal {
        family: plan.family,
        node: plan.node,
        profile: plan.profile,
        target: plan.routes[0].target.clone(),
        endpoint: plan.routes[0].endpoint.clone(),
        model: plan.model,
        body: body.into(),
        ceiling: 4,
        revision: 0,
        fence: 1,
    };
    request.validate().expect("valid untyped request");
    task.validate().expect("source metadata");
    let mut ledger = Ledger::open(&path).expect("ledger");
    ledger
        .publish(None, "permit(principal,action,resource);", 1)
        .expect("permissive Policy control");
    ledger
        .register_task(&task)
        .expect("original provider profile");
    assert!(!task.admits(&request));
    assert!(!raw.matches(&task));
    assert!(ledger.enqueue(&request).is_err());
    assert!(ledger.register_stream(&raw).is_err());
    assert_eq!(ledger.held("f").expect("hold"), 0);
}

#[test]
fn missing_artifact_identifier_cannot_erase_the_task_profile_floor() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("profile.db");
    let (mut ledger, _, plan) = source(&path);
    ledger.enqueue_provider(&plan).expect("hold");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    let connection = Session::open(&path).expect("inconsistent projection");
    let record: String = weaver_ledger::persistence::one(
        &connection,
        "SELECT record FROM tasks WHERE family='f'",
        (),
        |row| row.get(0),
    )
    .expect("record");
    let mut value: serde_json::Value = serde_json::from_str(&record).expect("metadata");
    value["provider_profile"]
        .as_object_mut()
        .expect("artifact")
        .remove("id");
    weaver_ledger::persistence::exec(
        &connection,
        "UPDATE tasks SET record=?1 WHERE family='f'",
        weaver_ledger::persistence::params![
            (serde_json::to_string(&value).expect("image")).to_owned()
        ],
    )
    .expect("restore partial artifact");
    let mut calls = 0;
    assert!(
        ledger
            .dispatch_provider(&permit, || {
                calls += 1;
                Ok(())
            })
            .is_err()
    );
    assert_eq!(calls, 0);
    assert_eq!(ledger.held("f").expect("hold"), 4);
}

#[test]
fn profile_collision_and_task_conflict_cannot_publish_partial_registration() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("profile.db");
    let (mut ledger, original, plan) = source(&path);
    ledger.enqueue_provider(&plan).expect("original hold");
    let mut collision = original.clone();
    collision.family = "other-family".into();
    collision
        .provider_profile
        .as_mut()
        .expect("profile")
        .max_output_tokens = 64;
    let mut other = plan.clone();
    other.family = collision.family.clone();
    other.profile_commitment = collision
        .provider_profile
        .as_ref()
        .expect("profile")
        .digest()
        .expect("digest");
    collision
        .stream_contracts
        .insert(other.node.clone(), other.digest().expect("plan"));
    assert!(ledger.register_task(&collision).is_err());
    let mut changed = original;
    changed.profile = "new-profile".into();
    changed.provider_profile.as_mut().expect("profile").id = changed.profile.clone();
    let mut replacement = plan.clone();
    replacement.profile = changed.profile.clone();
    replacement.profile_commitment = changed
        .provider_profile
        .as_ref()
        .expect("profile")
        .digest()
        .expect("digest");
    changed.stream_contracts.insert(
        replacement.node.clone(),
        replacement.digest().expect("plan"),
    );
    assert!(ledger.register_task(&changed).is_err());
    let observation = Session::open(&path).expect("observation");
    assert_eq!(
        weaver_ledger::persistence::one(
            &observation,
            "SELECT count(*) FROM tasks WHERE family='other-family'",
            (),
            |r| r.get::<i64>(0)
        )
        .expect("task"),
        0
    );
    assert_eq!(
        weaver_ledger::persistence::one(
            &observation,
            "SELECT count(*) FROM provider_profiles WHERE id='new-profile'",
            (),
            |r| r.get::<i64>(0)
        )
        .expect("profile"),
        0
    );
    assert_eq!(ledger.held("f").expect("original hold"), 4);
}

#[test]
fn restored_registry_mismatch_blocks_cached_dispatch_and_release() {
    for after_dispatch in [false, true] {
        let temp = tempfile::tempdir().expect("temp");
        let path = temp.path().join("profile.db");
        let (mut ledger, mut task, plan) = source(&path);
        ledger.enqueue_provider(&plan).expect("hold");
        let permit = ledger
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .expect("consume");
        let mut calls = 0;
        let pending = if after_dispatch {
            ledger
                .dispatch_provider(&permit, || {
                    calls += 1;
                    Ok(())
                })
                .expect("dispatch");
            Some(
                ledger
                    .prepare_provider_release(&permit, "batch", "protobuf", 1)
                    .expect("prepare"),
            )
        } else {
            None
        };
        // Model an inconsistent restored registry while its old digest column survives.
        task.provider_profile
            .as_mut()
            .expect("profile")
            .max_output_tokens = 16;
        let record = serde_json::to_string(task.provider_profile.as_ref().expect("profile"))
            .expect("record");
        weaver_ledger::persistence::exec(
            &weaver_ledger::persistence::Session::open(&path).expect("fault injector"),
            "UPDATE provider_profiles SET record=?1 WHERE id='p'",
            weaver_ledger::persistence::params![(record).to_owned()],
        )
        .expect("restore mismatch");
        if let Some(release) = pending {
            assert!(
                ledger
                    .release_provider(&permit, release, "protobuf", |_| {
                        calls += 1;
                        Ok(())
                    })
                    .is_err()
            );
        } else {
            assert!(
                ledger
                    .dispatch_provider(&permit, || {
                        calls += 1;
                        Ok(())
                    })
                    .is_err()
            );
        }
        assert_eq!(calls, usize::from(after_dispatch));
        assert_eq!(ledger.held("f").expect("hold"), 4);
        drop(ledger);
        let mut recovered = Ledger::open(&path).expect("restart");
        assert_eq!(recovered.held("f").expect("hold"), 4);
        assert_eq!(
            recovered
                .provider_receipt("f", "infer")
                .expect("receipt")
                .expect("original")
                .state,
            ProviderState::Unknown
        );
        assert!(
            recovered
                .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
                .is_err()
        );
    }
}

#[test]
fn concurrent_profile_registrations_cannot_fork_one_identity() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("profile.db");
    drop(Ledger::open(&path).expect("initialize"));
    let barrier = Arc::new(Barrier::new(2));
    let results = std::thread::scope(|scope| {
        let workers: Vec<_> = [64, 128]
            .into_iter()
            .map(|limit| {
                let barrier = barrier.clone();
                let path = &path;
                scope.spawn(move || {
                    let (mut task, mut plan) =
                        fixtures::task_plan(8, "https://provider.invalid/v1/chat/completions");
                    task.family = format!("family-{limit}");
                    task.provider_profile
                        .as_mut()
                        .expect("profile")
                        .max_output_tokens = limit;
                    plan.family = task.family.clone();
                    plan.profile_commitment = task
                        .provider_profile
                        .as_ref()
                        .expect("profile")
                        .digest()
                        .expect("profile digest");
                    task.stream_contracts
                        .insert(plan.node.clone(), plan.digest().expect("plan digest"));
                    let mut ledger = Ledger::open(path).expect("writer");
                    barrier.wait();
                    ledger.register_task(&task).is_ok()
                })
            })
            .collect();
        workers
            .into_iter()
            .map(|worker| worker.join().expect("writer exit"))
            .collect::<Vec<_>>()
    });
    assert_eq!(results.into_iter().filter(|ok| *ok).count(), 1);
    let connection = Session::open(&path).expect("observe");
    assert_eq!(
        weaver_ledger::persistence::one(
            &connection,
            "SELECT count(*) FROM provider_profiles",
            (),
            |r| r.get::<i64>(0)
        )
        .expect("profiles"),
        1
    );
    assert_eq!(
        weaver_ledger::persistence::one(&connection, "SELECT count(*) FROM tasks", (), |r| r
            .get::<i64>(0))
        .expect("tasks"),
        1
    );
}
