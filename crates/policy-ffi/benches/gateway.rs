use criterion::{Criterion, criterion_group, criterion_main};
use std::{hint::black_box, time::Duration};
#[path = "../../policy/benches/support/fixtures.rs"]
mod fixtures;

fn preflight(c: &mut Criterion) {
    c.bench_function("policy-ffi/typed_preflight", |b| {
        b.iter(|| {
            assert_eq!(
                black_box(weaver_policy_ffi::validate(
                    fixtures::POLICY.as_bytes(),
                    fixtures::SCHEMA.as_bytes(),
                )),
                0
            );
        })
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=preflight}
criterion_main!(benches);
