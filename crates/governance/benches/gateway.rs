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
    let original = weaver_governance::OwnedSource::from_source(data.clone()).expect("original");
    c.bench_function("governance/original_source_capture_and_bind", |b| {
        b.iter(|| {
            let expected = weaver_governance::SourceExpectation::capture(black_box(&original));
            let candidate = weaver_governance::OwnedSource::from_source(black_box(data.clone()))
                .expect("candidate");
            assert!(expected.bind(candidate).is_ok());
        })
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=source}
criterion_main!(benches);
