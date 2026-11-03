// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! One actual durable batch: prepare burn, fresh final guard and queue callback.
use criterion::{BatchSize, BenchmarkId, Criterion};
use std::{collections::BTreeSet, hint::black_box};

pub fn benchmarks(c: &mut Criterion) {
    let mut group = c.benchmark_group("ledger/provider_release");
    for rows in [1u64, 8, 32] {
        group.bench_with_input(BenchmarkId::from_parameter(rows), &rows, |b, &rows| {
            b.iter_batched(
                || {
                    let (temp, mut ledger, plan) =
                        super::stores::fresh(128, "https://provider.invalid/v1/chat/completions");
                    ledger
                        .enqueue_provider(&plan)
                        .expect("original reservation");
                    let permit = ledger
                        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
                        .expect("consume");
                    ledger
                        .dispatch_provider(&permit, || Ok(()))
                        .expect("single request burn");
                    (temp, ledger, permit)
                },
                |(temp, mut ledger, permit)| {
                    let release = ledger
                        .prepare_provider_release(&permit, "batch", "arrow", rows)
                        .expect("durable prepared interval");
                    ledger
                        .release_provider(&permit, release, "arrow", |first| {
                            assert_eq!(first, 0, "original sequence");
                            black_box(first);
                            Ok(())
                        })
                        .expect("fresh per-row Cedar guard");
                    assert_eq!(ledger.held("f").expect("conserved hold"), 4);
                    black_box((temp, ledger, permit))
                },
                BatchSize::PerIteration,
            )
        });
    }
    group.finish();
}
