// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! One actual durable batch: prepare burn, fresh final guard and queue callback.
use criterion::{BatchSize, BenchmarkId, Criterion};
use std::{collections::BTreeSet, hint::black_box};

pub fn benchmarks(c: &mut Criterion) {
    let mut group = c.benchmark_group("ledger/provider_release");
    for reviewed in [false, true] {
        for rows in [1u64, 8, 32] {
            group.bench_with_input(
                BenchmarkId::new(if reviewed { "reviewed" } else { "trusted-host" }, rows),
                &rows,
                |b, &rows| {
                    b.iter_batched(
                        || {
                            let (temp, mut ledger, plan) = fresh(reviewed);
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
                },
            );
        }
    }
    group.finish();
}

fn fresh(
    reviewed: bool,
) -> (
    tempfile::TempDir,
    weaver_ledger::Ledger,
    weaver_contracts::ProviderPlan,
) {
    let endpoint = "https://provider.invalid/v1/chat/completions";
    if !reviewed {
        return super::stores::fresh(128, endpoint);
    }
    super::stores::fresh_prepared(128, endpoint, |ledger, publication| {
        ledger
            .install_review_authority(&super::review_fixture::issuer(0))
            .expect("benchmark public verifier");
        let mut original =
            super::review_fixture::change(&publication.operation_id, publication.expected_revision);
        original.policy = publication.policy.clone();
        original.schema = publication.schema.clone();
        original.fence = publication.fence;
        let proof = super::review_fixture::evidence(ledger, &original);
        ledger
            .with_authenticated_source(&super::review_fixture::source(), |l| {
                l.register_delta_review(&proof)
            })
            .expect("synthetic producer authentication; not semantic qualification");
    })
}
