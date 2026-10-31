use criterion::{Criterion, criterion_group, criterion_main};
use std::{hint::black_box, time::Duration};
#[path = "support/fixture.rs"]
mod fixture;
fn source(c: &mut Criterion) {
    let data = fixture::source();
    c.bench_function("governance/owned_source_validate", |b| {
        b.iter(|| {
            assert!(weaver_governance::OwnedSource::from_source(black_box(data.clone())).is_ok());
        })
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=source}
criterion_main!(benches);
