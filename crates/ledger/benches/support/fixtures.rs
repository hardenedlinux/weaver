//! Fresh durable benchmark stores are provisioned outside timed iterations.
use weaver_contracts::{ProviderPlan, Publication};
use weaver_ledger::Ledger;
pub fn fresh(bytes: usize, endpoint: &str) -> (tempfile::TempDir, Ledger, ProviderPlan) {
    let temp = tempfile::tempdir().expect("benchmark store");
    let mut ledger = Ledger::open(temp.path().join("ledger.db")).expect("benchmark ledger");
    let publication = Publication {
        operation_id: "benchmark-original".into(),
        expected_revision: None,
        policy: super::policy_fixture::POLICY.into(),
        schema: super::policy_fixture::SCHEMA.into(),
        fence: 1,
    };
    let key = ledger
        .stage_authority(&publication)
        .expect("benchmark source barrier");
    let (task, plan) = super::fixtures::task_plan(bytes, endpoint);
    ledger
        .register_published_task(&task, &key)
        .expect("benchmark original task");
    ledger
        .publish_authority(&publication)
        .expect("benchmark committed task birth");
    (temp, ledger, plan)
}

/// Populate exact original plans outside measurement; only the selected final use is timed.
pub fn family(count: usize) -> (tempfile::TempDir, Ledger) {
    family_with_body(count, 128)
}

/// Retained original JSON bytes remain part of the deciding guard scan.
pub fn family_with_body(count: usize, bytes: usize) -> (tempfile::TempDir, Ledger) {
    let temp = tempfile::tempdir().expect("family store");
    let mut ledger = Ledger::open(temp.path().join("ledger.db")).expect("ledger");
    ledger
        .publish_typed(
            None,
            "permit(principal,action,resource);",
            super::policy_fixture::SCHEMA,
            1,
        )
        .expect("benchmark policy");
    let (mut task, original) =
        super::fixtures::task_plan(bytes, "https://provider.invalid/v1/chat/completions");
    task.nodes.clear();
    task.body_digests.clear();
    task.node_cost_bounds.clear();
    task.stream_contracts.clear();
    task.budget = count as u64 * 4;
    let mut plans = Vec::with_capacity(count);
    for index in 0..count {
        let mut plan = original.clone();
        if index > 0 {
            plan.node = format!("extra-{index}");
        }
        task.nodes.push(plan.node.clone());
        task.body_digests
            .insert(plan.node.clone(), weaver_contracts::body_digest(&plan.body));
        task.node_cost_bounds
            .insert(plan.node.clone(), plan.ceiling);
        task.stream_contracts
            .insert(plan.node.clone(), plan.digest().expect("commitment"));
        plans.push(plan);
    }
    ledger.register_task(&task).expect("original task");
    for plan in plans {
        ledger
            .enqueue_provider(&plan)
            .expect("retained reservation");
    }
    (temp, ledger)
}

/// One stream owns several original message commitments under one durable claim.
pub fn stream(count: usize) -> (tempfile::TempDir, Ledger, weaver_ledger::StreamOwner) {
    let temp = tempfile::tempdir().expect("stream store");
    let mut ledger = Ledger::open(temp.path().join("ledger.db")).expect("ledger");
    ledger
        .publish(None, "permit(principal,action,resource);", 1)
        .expect("policy");
    let (mut task, _) = super::fixtures::task_plan(128, "https://provider.invalid/");
    task.provider_profile = None;
    task.budget = count as u64 * 4;
    task.node_cost_bounds.insert("infer".into(), task.budget);
    let contract = weaver_contracts::StreamContract {
        family: task.family.clone(),
        node: "infer".into(),
        profile: task.profile.clone(),
        target: "primary".into(),
        input_digest: task.body_digests["infer"].clone(),
        destination: "tcp://127.0.0.1:9000".into(),
        messages: (0..count)
            .map(|index| weaver_contracts::MessageRule {
                id: format!("m{index}"),
                max_bytes: 8,
                cost_bound: 4,
            })
            .collect(),
    };
    let digest = contract.digest().expect("manifest");
    task.stream_contracts.insert("infer".into(), digest.clone());
    ledger.register_task(&task).expect("task");
    ledger.register_stream(&contract).expect("contract");
    for index in 0..count {
        ledger
            .enqueue_message(&weaver_contracts::StreamMessage {
                family: task.family.clone(),
                node: "infer".into(),
                message: format!("m{index}"),
                contract_digest: digest.clone(),
                payload: "abcdefgh".into(),
                ceiling: 4,
                revision: 0,
                fence: 1,
            })
            .expect("original message");
    }
    let owner = ledger
        .claim_stream(weaver_ledger::StreamClaim {
            family: &task.family,
            node: "infer",
            destination: &contract.destination,
            revision: 0,
            fence: 1,
        })
        .expect("custody");
    (temp, ledger, owner)
}
