use criterion::{Criterion, criterion_group, criterion_main};
use std::{hint::black_box, path::Path, time::Duration};
fn staging(c: &mut Criterion) {
    c.bench_function("governance-build/staging_expression", |b| {
        b.iter(|| {
            weaver_governance_build::staging_expression(
                black_box(Path::new("/tmp/package/t/fixtures/governance-program.ss")),
                Path::new("/tmp/prefix/lib"),
                Path::new("/tmp/cargo-out/program"),
            )
            .expect("paths")
        })
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=staging}
criterion_main!(benches);
