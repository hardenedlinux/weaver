use criterion::{Criterion, criterion_group, criterion_main};
use std::{hint::black_box, time::Duration};
#[path = "../../contracts/benches/support/fixtures.rs"]
mod fixtures;
#[path = "support/fixtures.rs"]
mod policy_fixture;
fn current_policy(c: &mut Criterion) {
    let (task, plan) = fixtures::task_plan(128, "https://provider.invalid/v1/chat/completions");
    let binding = weaver_policy::bind_provider(&task, &plan, &plan.routes[0]).expect("binding");
    c.bench_function("policy/typed_schema_validation", |b| {
        b.iter(|| {
            black_box(weaver_policy::validate_typed(
                policy_fixture::POLICY,
                policy_fixture::SCHEMA,
            ))
            .expect("typed policy")
        })
    });
    c.bench_function("policy/warm_compilation_current_decision", |b| {
        b.iter(|| {
            black_box(binding.authorize(
                policy_fixture::POLICY,
                weaver_policy::ProviderCheck {
                    action: "emitProvider",
                    sequence: 1,
                    format: "protobuf",
                },
            ))
            .expect("current decision")
        })
    });
    let sources: Vec<_> = (0..16)
        .map(|i| {
            format!(
                "{}\n// exact-source cache churn {i}",
                policy_fixture::POLICY
            )
        })
        .collect();
    let mut index = 0;
    c.bench_function("policy/compilation_cache_churn", |b| {
        b.iter(|| {
            let result = weaver_policy::validate(&sources[index % 16]);
            index += 1;
            black_box(result).expect("source compilation")
        })
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=current_policy}
criterion_main!(benches);
