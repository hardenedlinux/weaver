// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Fresh durable benchmark stores are provisioned outside timed iterations.
use weaver_contracts::{ProviderPlan, Publication};
use weaver_ledger::Ledger;
pub fn fresh(bytes: usize, endpoint: &str) -> (tempfile::TempDir, Ledger, ProviderPlan) {
    fresh_prepared(bytes, endpoint, |_, _| {})
}
/// One common fixture; optional trusted provisioning remains outside timed work.
/// Callers own their specific setup and dependencies, including test signers.
pub fn fresh_prepared(
    bytes: usize,
    endpoint: &str,
    prepare: impl FnOnce(&mut Ledger, &Publication),
) -> (tempfile::TempDir, Ledger, ProviderPlan) {
    let temp = tempfile::tempdir().expect("benchmark store");
    let mut ledger = Ledger::open(temp.path().join("ledger.db")).expect("benchmark ledger");
    let publication = Publication {
        operation_id: "benchmark-original".into(),
        expected_revision: None,
        policy: super::policy_fixture::POLICY.into(),
        schema: super::policy_fixture::SCHEMA.into(),
        fence: 1,
    };
    prepare(&mut ledger, &publication);
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
