use criterion::{BatchSize, Criterion, criterion_group, criterion_main};
use std::{collections::BTreeSet, hint::black_box, time::Duration};
#[path = "../../../dev/benchmarks/contracts.rs"]
mod fixtures;
#[path = "../../../dev/benchmarks/policy.rs"]
mod policy_fixture;
#[path = "../../../dev/benchmarks/store.rs"]
mod stores;
fn durable_operations(c: &mut Criterion) {
    c.bench_function("ledger/fresh_admission", |b| {
        b.iter_batched(
            || stores::fresh(128, "https://provider.invalid/v1/chat/completions"),
            |(temp, mut ledger, plan)| {
                let receipt = ledger.enqueue_provider(&plan).expect("admission");
                assert_eq!(receipt.reserved, 4);
                black_box((temp, ledger, receipt))
            },
            BatchSize::PerIteration,
        )
    });
    c.bench_function("ledger/consume_and_dispatch_burn", |b| {
        b.iter_batched(
            || {
                let (temp, mut ledger, plan) =
                    stores::fresh(128, "https://provider.invalid/v1/chat/completions");
                ledger.enqueue_provider(&plan).expect("queue");
                (temp, ledger)
            },
            |(temp, mut ledger)| {
                let permit = ledger
                    .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
                    .expect("consume");
                ledger
                    .dispatch_provider(&permit, || black_box(()))
                    .expect("guarded callback");
                assert_eq!(ledger.held("f").expect("hold"), 4);
                black_box((temp, ledger))
            },
            BatchSize::PerIteration,
        )
    });
    let (_temp, mut ledger, plan) =
        stores::fresh(128, "https://provider.invalid/v1/chat/completions");
    ledger.enqueue_provider(&plan).expect("queue");
    c.bench_function("ledger/idempotent_admission", |b| {
        b.iter(|| {
            let receipt = ledger.enqueue_provider(&plan).expect("same root");
            assert_eq!(receipt.reserved, 4);
            black_box(receipt)
        })
    });
}
fn publication_operations(c: &mut Criterion) {
    let change = weaver_contracts::Publication {
        operation_id: "measured".into(),
        expected_revision: Some(0),
        fence: 1,
        policy: policy_fixture::POLICY.into(),
        schema: policy_fixture::SCHEMA.into(),
    };
    c.bench_function("ledger/publication_atomic_commit", |b| {
        b.iter_batched(
            || stores::fresh(128, "https://provider.invalid/v1/chat/completions"),
            |(temp, mut ledger, _)| {
                let receipt = ledger
                    .publish_authority(&change)
                    .expect("atomic publication");
                assert_eq!(
                    receipt.outcome,
                    weaver_contracts::PublicationOutcome::Committed
                );
                black_box((temp, ledger, receipt))
            },
            BatchSize::PerIteration,
        )
    });
    let (_temp, mut ledger, _) = stores::fresh(128, "https://provider.invalid/v1/chat/completions");
    let receipt = ledger
        .publish_authority(&change)
        .expect("original decision");
    c.bench_function("ledger/publication_exact_replay", |b| {
        b.iter(|| {
            assert_eq!(
                black_box(ledger.publish_authority(&change).expect("replay")),
                receipt
            )
        })
    });
    let key = weaver_contracts::PublicationKey {
        operation_id: change.operation_id,
        digest: receipt.digest.clone(),
    };
    c.bench_function("ledger/publication_historical_lookup", |b| {
        b.iter(|| {
            assert_eq!(
                black_box(ledger.publication_receipt(&key).expect("lookup")),
                Some(receipt.clone())
            )
        })
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=durable_operations,publication_operations}
criterion_main!(benches);
