//! Warm owner-local conversion; startup, compilation and authority are excluded.
use criterion::{BenchmarkId, Criterion, SamplingMode, Throughput};
use std::{hint::black_box, time::Duration};
#[path = "../tests/unit/fixture.rs"]
mod fixture;
#[path = "../tests/integration/program.rs"]
mod program;

fn main() {
    let mut criterion = Criterion::default()
        .sample_size(30)
        .warm_up_time(Duration::from_secs(1))
        .measurement_time(Duration::from_secs(2))
        .configure_from_args();
    assert_eq!(weaver_policy_ffi::weaver_policy_abi_v1(), 0x0001_0000);
    let vm = program::initialize();
    // Retain the actual AA export binding as part of graph qualification.
    let capture = program::capture(&vm);
    let mut group = criterion.benchmark_group("governance/scheme_string");
    for (name, unit) in [("ascii", "a"), ("unicode", "λ🙂\0")] {
        for count in [64, 16384, 262144] {
            let input = unit.repeat(count);
            let root = vm.string_from_utf8(&input).expect("root");
            group.throughput(Throughput::Bytes(input.len() as u64));
            group.bench_with_input(
                BenchmarkId::new(format!("{name}-snapshot"), count),
                &root,
                |b, root| {
                    b.iter(|| {
                        let snapshot = root.to_utf8_bytes().into_result().expect("snapshot");
                        black_box(
                            String::from_utf8(snapshot.to_vec().into_result().expect("copy"))
                                .expect("UTF-8"),
                        )
                    });
                },
            );
            group.bench_with_input(
                BenchmarkId::new(format!("{name}-direct"), count),
                &root,
                |b, root| {
                    b.iter(|| black_box(root.to_string().into_result().expect("direct")));
                },
            );
        }
    }
    group.finish();
    let owned = weaver_governance::OwnedSource::from_source(fixture::source()).expect("source");
    let mut group = criterion.benchmark_group("governance/scheme_source");
    group.bench_function("roundtrip", |b| {
        b.iter(|| {
            let root = weaver_governance::root_source(&vm, black_box(&owned)).expect("input");
            black_box(
                weaver_governance::materialize_bound_source(
                    root,
                    weaver_governance::SourceExpectation::capture(&owned),
                )
                .expect("bound"),
            )
        })
    });
    group.sampling_mode(SamplingMode::Flat);
    group.bench_function("assessed_capture", |b| {
        b.iter(|| {
            let expected = weaver_governance::SourceExpectation::capture(black_box(&owned));
            let root = weaver_governance::root_source(&vm, &owned).expect("original input");
            let output = capture.call(&root).into_result().expect("AA capture");
            black_box(
                weaver_governance::materialize_bound_source(output, expected)
                    .expect("original-bound assessed source"),
            )
        })
    });
    group.finish();
    // No root, borrowed heap view or callback outlives natural VM cleanup.
    drop(owned);
    drop(vm);
    criterion.final_summary();
}
