// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::persistence::{Session, exec, one};
use weaver_contracts::{
    CatalogEntry, ProviderCatalog, ProviderOperationScope, ProviderPlan, ProviderProfile,
    ProviderQuote, ProviderRoute, ProviderRoutingScope, Publication, RoutingCandidate,
    RoutingSelection, SourceIdentity, SourceRotation, Task, body_digest, decode,
};
use weaver_ledger::Ledger;

fn identity(id: u8) -> SourceIdentity {
    SourceIdentity {
        certificate_sha256: body_digest(&format!("cert-{id}")),
        public_key_sha256: body_digest(&format!("key-{id}")),
        credential_sha256: body_digest("source"),
    }
}
fn fixture(
    path: &std::path::Path,
) -> (
    Ledger,
    ProviderRoutingScope,
    Task,
    ProviderPlan,
    ProviderCatalog,
) {
    let mut ledger = Ledger::open(path).expect("ledger");
    let profile: ProviderProfile = decode(include_bytes!(
        "../../../../prod/policies/provider/profile.json"
    ))
    .expect("profile");
    let plan=ProviderPlan { family:"f".into(),node:"infer".into(),profile:"p".into(),profile_commitment:profile.digest().expect("profile digest"),model:"model-a".into(),body:r#"{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":32}"#.into(),routes:vec![ProviderRoute { target:"primary".into(),endpoint:"https://provider.invalid/v1/chat/completions".into() }],ceiling:4,revision:0,fence:1 };
    let task = Task {
        family: "f".into(),
        principal: "alice".into(),
        profile: "p".into(),
        provider_profile: Some(profile),
        nodes: vec!["infer".into()],
        targets: vec!["primary".into()],
        endpoints: [("primary".into(), plan.routes[0].endpoint.clone())].into(),
        body_digests: [("infer".into(), body_digest(&plan.body))].into(),
        stream_contracts: [("infer".into(), plan.digest().expect("plan digest"))].into(),
        node_cost_bounds: [("infer".into(), 4)].into(),
        models: vec!["model-a".into()],
        budget: 8,
    };
    let mut raw = task.clone();
    raw.body_digests.clear();
    raw.stream_contracts.clear();
    let scope = ProviderRoutingScope {
        task: raw,
        selection_schema: "provider-v1".into(),
        selection: RoutingSelection {
            node: "infer".into(),
            allowed_modules: vec!["premium".into()],
            required: vec!["quality".into()],
            max_latency_ms: 100,
            max_procurement_cost: 100,
            user_token_rates: [1, 0, 0, 0],
            candidates: vec![RoutingCandidate {
                module: "premium".into(),
                capabilities: vec!["quality".into()],
                latency_ms: 1,
                procurement_rates: [1, 0, 0, 0],
                token_bounds: [64, 0, 0, 32],
                plan: plan.clone(),
            }],
        },
        publication: Publication {
            operation_id: "routing-pub".into(),
            expected_revision: None,
            fence: 1,
            policy: include_str!("../../../../prod/policies/provider/provider.cedar").into(),
            schema: include_str!("../../../../prod/policies/provider/schema.json").into(),
        },
    };
    assert!(
        ledger.register_provider_routing(&scope).is_err(),
        "no implicit trusted-host delegation"
    );
    ledger
        .with_authenticated_source(&identity(0), |ledger| {
            ledger.stage_authority(&scope.publication)
        })
        .expect("stage");
    ledger
        .with_authenticated_source(&identity(0), |ledger| {
            ledger.register_provider_routing(&scope)
        })
        .expect("declare");
    assert!(
        ledger.provider_operation_cut("f", "infer").is_err(),
        "staged is not active"
    );
    ledger
        .with_authenticated_source(&identity(0), |ledger| {
            ledger.publish_authority(&scope.publication)
        })
        .expect("activate");
    let catalog = ProviderCatalog {
        parent: String::new(),
        entries: [(
            plan.digest().expect("digest"),
            CatalogEntry {
                module: "premium".into(),
                capabilities: vec!["quality".into()],
                latency_millis: 1,
                user_rates: [1, 0, 0, 0],
                quote: ProviderQuote {
                    version: "v1".into(),
                    tenant: "tenant".into(),
                    formula_digest: body_digest("test formula"),
                    procurement_rates: [1, 0, 0, 0],
                    token_bounds: [64, 0, 0, 32],
                },
            },
        )]
        .into(),
    };
    insert_catalog(path, 1, &catalog);
    (ledger, scope, task, plan, catalog)
}
fn insert_catalog(path: &std::path::Path, revision: i64, catalog: &ProviderCatalog) {
    let session = Session::open(path).expect("catalog fixture");
    exec(
        &session,
        "INSERT INTO provider_catalog_publications VALUES(?1,?2,?3)",
        crate::persistence::params![
            revision,
            catalog.digest().expect("digest"),
            String::from_utf8(catalog.record().expect("record")).expect("UTF-8")
        ],
    )
    .expect("catalog");
}
#[test]
fn routed_registration_rechecks_catalog_and_preserves_restart_scope() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("routing.db");
    let (mut ledger, scope, task, plan, mut catalog) = fixture(&path);
    let stale = ledger
        .provider_operation_cut("f", "infer")
        .expect("cut")
        .expect("scope");
    catalog.parent = catalog.digest().expect("parent");
    catalog
        .entries
        .values_mut()
        .next()
        .expect("entry")
        .latency_millis = 2;
    insert_catalog(&path, 2, &catalog);
    assert!(
        ledger.register_routed_task(&stale, &task, &plan).is_err(),
        "old catalog cannot register"
    );
    let session = Session::open(&path).expect("inspect");
    let count: i64 =
        one(&session, "SELECT COUNT(*) FROM tasks", (), |row| row.get(0)).expect("count");
    assert_eq!(count, 0);
    let current = ledger
        .provider_operation_cut("f", "infer")
        .expect("cut")
        .expect("scope");
    let mut modified = plan.clone();
    modified.body.push(' ');
    assert!(
        ledger
            .register_routed_task(&current, &task, &modified)
            .is_err(),
        "candidate mutation"
    );
    ledger
        .register_routed_task(&current, &task, &plan)
        .expect("current exact registration");
    ledger.close().expect("close");
    let mut ledger = Ledger::open(&path).expect("restart");
    assert_eq!(
        ledger
            .provider_operation_cut("f", "infer")
            .expect("cut")
            .expect("scope")
            .binding
            .scope,
        ProviderOperationScope::Catalog { routing: scope }
    );
    ledger
        .register_routed_task(&current, &task, &plan)
        .expect("idempotent restart registration");
}
#[test]
fn source_rotation_and_record_corruption_cannot_reuse_routing_cut() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("routing.db");
    let (mut ledger, scope, task, plan, _) = fixture(&path);
    let observed = ledger
        .provider_operation_cut("f", "infer")
        .expect("cut")
        .expect("scope");
    let mut other = Ledger::open(&path).expect("other");
    other
        .rotate_source_authority(
            &identity(0),
            &SourceRotation {
                operation_id: "rotate".into(),
                expected_epoch: 0,
                next: identity(1),
            },
        )
        .expect("rotate");
    assert!(
        ledger
            .register_routed_task(&observed, &task, &plan)
            .is_err(),
        "old source cannot register"
    );
    assert!(
        ledger.provider_operation_cut("f", "infer").is_err(),
        "old declaration cannot survive source retirement"
    );
    assert!(
        ledger
            .with_authenticated_source(&identity(1), |ledger| ledger
                .register_provider_routing(&scope))
            .is_err(),
        "new source cannot silently replace original scope"
    );
    let session = Session::open(&path).expect("corrupt");
    exec(
        &session,
        "UPDATE provider_operation_scopes SET record='{}'",
        (),
    )
    .expect("inject corruption");
    assert!(ledger.provider_operation_cut("f", "infer").is_err());
}
