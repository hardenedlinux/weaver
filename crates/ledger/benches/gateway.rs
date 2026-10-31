use criterion::{BatchSize, BenchmarkId, Criterion, criterion_group, criterion_main};
use std::{collections::BTreeSet, hint::black_box, time::Duration};
#[path = "../../contracts/benches/support/fixtures.rs"]
mod fixtures;
#[path = "../../policy/benches/support/fixtures.rs"]
mod policy_fixture;
#[path = "support/fixtures.rs"]
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
    c.bench_function("ledger/publication_stage_and_decide", |b| {
        b.iter_batched(
            || stores::fresh(128, "https://provider.invalid/v1/chat/completions"),
            |(temp, mut ledger, _)| {
                let key = ledger.stage_authority(&change).expect("durable barrier");
                let receipt = ledger
                    .publish_authority(&change)
                    .expect("atomic resolution");
                assert_eq!(key.digest, receipt.digest);
                assert_eq!(
                    receipt.outcome,
                    weaver_contracts::PublicationOutcome::Committed
                );
                black_box((temp, ledger, receipt))
            },
            BatchSize::PerIteration,
        )
    });
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
fn reviewed_publication(c: &mut Criterion) {
    let change = weaver_contracts::Publication {
        operation_id: "reviewed-benchmark".into(),
        expected_revision: Some(0),
        fence: 1,
        policy: policy_fixture::POLICY.into(),
        schema: policy_fixture::SCHEMA.into(),
    };
    c.bench_function("ledger/reviewed_publication_register_and_commit", |b| {
        b.iter_batched(
            || {
                let (temp, mut ledger, _) =
                    stores::fresh(128, "https://provider.invalid/v1/chat/completions");
                let publication = ledger
                    .stage_reviewed_authority(&change)
                    .expect("review latch");
                let parent = ledger
                    .required_review_parent(&publication)
                    .expect("independent parent");
                (
                    temp,
                    ledger,
                    weaver_contracts::PublicationReview {
                        publication,
                        parent,
                        artifact: "trusted-host-benchmark".repeat(1024),
                    },
                )
            },
            |(temp, mut ledger, review)| {
                ledger
                    .register_approved_review(&review)
                    .expect("exact local registration");
                let receipt = ledger
                    .publish_authority(&change)
                    .expect("guarded final CAS");
                assert_eq!(
                    receipt.outcome,
                    weaver_contracts::PublicationOutcome::Committed
                );
                black_box((temp, ledger, receipt))
            },
            BatchSize::PerIteration,
        )
    });
}
fn profile_registration(c: &mut Criterion) {
    let (task, _) = fixtures::task_plan(128, "https://provider.invalid/v1/chat/completions");
    c.bench_function("ledger/profile_task_registration", |b| {
        b.iter_batched(
            || {
                let temp = tempfile::tempdir().expect("temporary store");
                let ledger =
                    weaver_ledger::Ledger::open(temp.path().join("profile.db")).expect("ledger");
                (temp, ledger)
            },
            |(temp, mut ledger)| {
                ledger
                    .register_task(&task)
                    .expect("atomic profile and task");
                black_box((temp, ledger))
            },
            BatchSize::PerIteration,
        )
    });
    let mut group = c.benchmark_group("ledger/profile_task_replay");
    for count in [1, 256] {
        let (_temp, mut ledger, plan) =
            stores::fresh(128, "https://provider.invalid/v1/chat/completions");
        for i in 1..count {
            let mut other = task.clone();
            let mut bound = plan.clone();
            other.family = format!("profile-family-{i}");
            bound.family = other.family.clone();
            other
                .stream_contracts
                .insert(bound.node.clone(), bound.digest().expect("binding"));
            ledger
                .register_task(&other)
                .expect("shared profile floor fixture");
        }
        group.bench_with_input(BenchmarkId::from_parameter(count), &count, |b, _| {
            b.iter(|| {
                ledger
                    .register_task(black_box(&task))
                    .expect("exact original replay");
                black_box(())
            })
        });
    }
    group.finish();
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=durable_operations,publication_operations,profile_registration,reviewed_publication}
criterion_main!(benches);
