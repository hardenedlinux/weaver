// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use criterion::{Criterion, criterion_group, criterion_main};
use std::{hint::black_box, time::Duration};
#[path = "../../policy/benches/support/fixtures.rs"]
mod fixtures;

fn preflight(c: &mut Criterion) {
    let documents = [fixtures::POLICY, "forbid(principal,action,resource);"];
    let aggregate = documents.join("\n");
    c.bench_function("policy-ffi/document_and_aggregate_preflight", |b| {
        b.iter(|| {
            for source in documents
                .iter()
                .copied()
                .chain(std::iter::once(aggregate.as_str()))
            {
                assert_eq!(
                    black_box(weaver_policy_ffi::validate(
                        source.as_bytes(),
                        fixtures::SCHEMA.as_bytes(),
                    )),
                    0
                );
            }
        })
    });
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
