//! Fresh durable benchmark stores are provisioned outside timed iterations.
use weaver_contracts::ProviderPlan;
use weaver_ledger::Ledger;
pub fn fresh(bytes: usize, endpoint: &str) -> (tempfile::TempDir, Ledger, ProviderPlan) {
    let temp = tempfile::tempdir().expect("benchmark store");
    let mut ledger = Ledger::open(temp.path().join("ledger.db")).expect("benchmark ledger");
    ledger
        .publish_typed(
            None,
            super::policy_fixture::POLICY,
            super::policy_fixture::SCHEMA,
            1,
        )
        .expect("benchmark policy");
    let (task, plan) = super::fixtures::task_plan(bytes, endpoint);
    ledger
        .register_task(&task)
        .expect("benchmark original task");
    (temp, ledger, plan)
}
