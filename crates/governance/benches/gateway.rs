// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use criterion::{Criterion, criterion_group, criterion_main};
use std::{hint::black_box, time::Duration};
#[path = "support/catalog.rs"]
mod catalog;
#[path = "../tests/unit/fixture.rs"]
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
    let capacity = std::thread::available_parallelism().expect("host capacity");
    let (client, inbox) = weaver_governance::source_lane(capacity);
    let worker = std::thread::spawn(move || {
        inbox.run(|source| weaver_governance::OwnedSource::from_source(source.data().clone()));
    });
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("caller runtime");
    c.bench_function("governance/source_lane_roundtrip", |b| {
        b.iter(|| {
            let input = weaver_governance::OwnedSource::from_source(black_box(data.clone()))
                .expect("original");
            assert!(
                runtime
                    .block_on(client.submit(input).expect("admission"))
                    .is_ok()
            );
        });
    });
    client.close();
    worker.join().expect("owner drained");
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=source,catalog::catalog}
criterion_main!(benches);
