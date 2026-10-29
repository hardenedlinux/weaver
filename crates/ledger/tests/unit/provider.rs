use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use std::collections::BTreeSet;
use weaver_contracts::{ProviderPlan, ProviderRoute, Task, body_digest};
use weaver_ledger::{Ledger, ProviderDispatch, ProviderRelease};
const POLICY: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../dev/policies/provider/provider.cedar"
));
const SCHEMA: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../dev/policies/provider/schema.json"
));
fn fixture(path: &std::path::Path) -> (Ledger, ProviderPlan) {
    fixture_nodes(path, &["infer"])
}
fn fixture_nodes(path: &std::path::Path, nodes: &[&str]) -> (Ledger, ProviderPlan) {
    let mut ledger = Ledger::open(path).expect("ledger");
    let policy = POLICY.replace(
        "context.node == \"infer\"",
        "[\"infer\", \"second\"].contains(context.node)",
    );
    ledger
        .publish_typed(None, &policy, SCHEMA, 1)
        .expect("typed policy");
    let plan=ProviderPlan{family:"f".into(),node:"infer".into(),profile:"p".into(),model:"model-a".into(),body:r#"{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":32}"#.into(),routes:vec![ProviderRoute{target:"primary".into(),endpoint:"https://provider.invalid/v1/chat/completions".into()}],ceiling:4,revision:0,fence:1};
    ledger
        .register_task(&Task {
            family: "f".into(),
            principal: "alice".into(),
            profile: "p".into(),
            nodes: nodes.iter().map(|node| (*node).into()).collect(),
            targets: vec!["primary".into()],
            endpoints: [("primary".into(), plan.routes[0].endpoint.clone())].into(),
            body_digests: nodes
                .iter()
                .map(|node| ((*node).into(), body_digest(&plan.body)))
                .collect(),
            node_cost_bounds: nodes.iter().map(|node| ((*node).into(), 4)).collect(),
            stream_contracts: nodes
                .iter()
                .map(|node| {
                    let mut original = plan.clone();
                    original.node = (*node).into();
                    ((*node).into(), original.digest().expect("digest"))
                })
                .collect(),
            models: vec!["model-a".into()],
            budget: 8,
        })
        .expect("task");
    (ledger, plan)
}
#[test]
fn equal_batch_digests_cannot_transfer_release_between_original_nodes() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("provider.db");
    let (mut ledger, plan) = fixture_nodes(&path, &["infer", "second"]);
    let mut second = plan.clone();
    second.node = "second".into();
    let mut owners = Vec::new();
    for plan in [&plan, &second] {
        ledger.enqueue_provider(plan).expect("queue");
        let owner = ledger
            .consume_provider("f", &plan.node, &BTreeSet::from(["primary".into()]))
            .expect("consume");
        ledger.dispatch_provider(&owner, || ()).expect("dispatch");
        owners.push(owner);
    }
    let first_release = ledger
        .prepare_provider_release(&owners[0], "same-batch-digest", "arrow", 2)
        .expect("first release");
    let second_release = ledger
        .prepare_provider_release(&owners[1], "same-batch-digest", "arrow", 2)
        .expect("second release");
    let mut calls = 0;
    assert!(
        ledger
            .release_provider(&owners[1], first_release, "arrow", |_| {
                calls += 1;
                Ok(())
            })
            .is_err(),
        "foreign logical node admitted release"
    );
    assert_eq!(calls, 0);
    ledger
        .release_provider(&owners[1], second_release, "arrow", |first| {
            assert_eq!(first, 0);
            calls += 1;
            Ok(())
        })
        .expect("original second release");
    assert_eq!(calls, 1);
    assert!(
        ledger
            .prepare_provider_release(&owners[0], "same-batch-digest", "arrow", 2)
            .is_err(),
        "unknown first release must remain spent"
    );
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert_eq!(ledger.held("f").expect("shared hold"), 8);
    for owner in owners {
        assert!(
            ledger
                .consume_provider("f", &owner.plan().node, &BTreeSet::from(["primary".into()]))
                .is_err()
        );
    }
}
#[test]
fn release_encoding_cannot_change_after_preparation() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("provider.db");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("queue");
    let owner = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    ledger.dispatch_provider(&owner, || ()).expect("dispatch");
    let release = ledger
        .prepare_provider_release(&owner, "same-batch-digest", "arrow", 1)
        .expect("release");
    let mut calls = 0;
    assert!(
        ledger
            .release_provider(&owner, release, "protobuf", |_| {
                calls += 1;
                Ok(())
            })
            .is_err(),
        "prepared encoding changed at final release"
    );
    assert_eq!(calls, 0);
    assert!(
        ledger
            .prepare_provider_release(&owner, "same-batch-digest", "arrow", 1)
            .is_err()
    );
    assert_eq!(ledger.held("f").expect("hold"), 4);
}
#[test]
fn affine_provider_dispatch_and_revoked_batch_never_repeat_or_refund() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("provider.db");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("queue");
    let owner = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    assert!(
        ledger
            .prepare_provider_release(&owner, "digest", "arrow", 2)
            .is_err(),
        "no response before dispatch burn"
    );
    let mut calls = 0;
    ledger
        .dispatch_provider(&owner, || calls += 1)
        .expect("dispatch");
    assert!(ledger.dispatch_provider(&owner, || calls += 1).is_err());
    assert_eq!(calls, 1);
    let release = ledger
        .prepare_provider_release(&owner, "digest", "arrow", 2)
        .expect("prepare batch");
    ledger
        .publish_typed(Some(0), "forbid(principal,action,resource);", SCHEMA, 2)
        .expect("revoke");
    let mut releases = 0;
    assert!(
        ledger
            .release_provider(&owner, release, "arrow", |_| {
                releases += 1;
                Ok(())
            })
            .is_err()
    );
    assert_eq!(releases, 0);
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert!(ledger.dispatch_provider(&owner, || calls += 1).is_err());
    assert!(
        ledger
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .is_err()
    );
    assert_eq!(ledger.held("f").expect("held"), 4);
}
proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn release_capabilities_bind_plan_encoding_and_restart_session(
        rows in 1u64..33, prepared_arrow in proptest::bool::ANY,
        requested_arrow in proptest::bool::ANY, foreign_plan in proptest::bool::ANY,
        restart in proptest::bool::ANY,
    ) {
        let temp = tempfile::tempdir().expect("temp");
        let path = temp.path().join("provider.db");
        let (mut ledger, plan) = fixture_nodes(&path, &["infer", "second"]);
        let mut second = plan.clone();
        second.node = "second".into();
        let mut owners = Vec::new();
        for original in [&plan, &second] {
            ledger.enqueue_provider(original).expect("queue");
            let owner = ledger.consume_provider("f", &original.node, &BTreeSet::from(["primary".into()])).expect("consume");
            ledger.dispatch_provider(&owner, || ()).expect("dispatch");
            owners.push(owner);
        }
        let prepared = if prepared_arrow {"arrow"} else {"protobuf"};
        let requested = if requested_arrow {"arrow"} else {"protobuf"};
        let first = ledger.prepare_provider_release(&owners[0], "same-batch", prepared, rows).expect("first release");
        let _second = ledger.prepare_provider_release(&owners[1], "same-batch", requested, rows).expect("second release");
        if restart {
            drop(ledger);
            ledger = Ledger::open(&path).expect("restart");
        }
        let mut calls = 0;
        let result = ledger.release_provider(&owners[usize::from(foreign_plan)], first, requested, |_| {calls += 1; Ok(())});
        let expected = !foreign_plan && !restart && prepared_arrow == requested_arrow;
        prop_assert_eq!(result.is_ok(), expected);
        prop_assert_eq!(calls, usize::from(expected));
        prop_assert_eq!(ledger.held("f").expect("shared hold"), 8);
    }
    #[test]
    fn arbitrary_provider_replays_restarts_and_release_batches_keep_original_claim(events in proptest::collection::vec((0u8..8,1u64..4),1..40)) {
        let temp=tempfile::tempdir().expect("temp");let path=temp.path().join("provider.db");let(mut ledger,mut plan)=fixture(&path);
        let mut owner:Option<ProviderDispatch>=None;let mut release:Option<(ProviderRelease,u64)>=None;
        let mut admitted=false;let mut calls=0;let mut rows=BTreeSet::new();
        for(action,length)in events {
            match action {
                0=>{if ledger.enqueue_provider(&plan).is_ok(){admitted=true;}},
                1=>{if let Ok(permit)=ledger.consume_provider("f","infer",&BTreeSet::from(["primary".into()])){owner=Some(permit);}},
                2=>{if let Some(ref permit)=owner {let _=ledger.dispatch_provider(permit,||calls+=1);}},
                3=>{if release.is_none() && let Some(ref permit)=owner && let Ok(r)=ledger.prepare_provider_release(permit,"batch-digest","arrow",length){release=Some((r,length));}},
                4=>{if let (Some(permit),Some((r,count)))=(owner.as_ref(),release.take()){let _=ledger.release_provider(permit,r,"arrow",|start|{for row in start..start+count {assert!(rows.insert(row),"repeated logical response row");}Ok(())});}},
                5=>{drop(ledger);ledger=Ledger::open(&path).expect("restart");},
                6=>{plan.revision=ledger.publish_typed(Some(plan.revision),POLICY,SCHEMA,plan.fence+1).expect("publish");plan.fence+=1;},
                _=>{let mut forged=plan.clone();forged.profile="forged".into();prop_assert!(ledger.enqueue_provider(&forged).is_err());},
            }
            prop_assert!(calls<=1);prop_assert_eq!(ledger.held("f").expect("held"),if admitted {4}else{0});
        }
    }
}
