// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use std::{hint::black_box, time::Duration};
#[path = "support/fixtures.rs"]
mod fixtures;
#[path = "support/source_authority.rs"]
mod source_fixture;
fn commitments(c: &mut Criterion) {
    let mut group = c.benchmark_group("contracts/provider_commitment");
    for bytes in [128, 16384, 524288] {
        let (task, plan) =
            fixtures::task_plan(bytes, "https://provider.invalid/v1/chat/completions");
        assert!(plan.matches(&task).expect("original task"));
        group.throughput(Throughput::Bytes(plan.body.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(bytes), &plan, |b, p| {
            b.iter(|| black_box(p.digest().expect("commitment")))
        });
    }
    group.finish();
    let publication = weaver_contracts::Publication {
        operation_id: "benchmark".into(),
        expected_revision: Some(0),
        fence: 2,
        policy: format!(
            "//{}\n{}",
            "x".repeat(16384),
            include_str!("../../../prod/policies/provider/provider.cedar")
        ),
        schema: include_str!("../../../prod/policies/provider/schema.json").into(),
    };
    c.bench_function("contracts/publication_commitment", |b| {
        b.iter(|| black_box(publication.digest().expect("publication commitment")))
    });
    let review = weaver_contracts::PublicationReview {
        publication: weaver_contracts::PublicationKey {
            operation_id: publication.operation_id.clone(),
            digest: publication.digest().expect("command"),
        },
        parent: None,
        artifact: "upstream-evidence".repeat(1024),
    };
    c.bench_function("contracts/publication_review_commitment", |b| {
        b.iter(|| black_box(review.digest().expect("exact artifact commitment")))
    });
}
fn profile_contracts(c: &mut Criterion) {
    let profile: weaver_contracts::ProviderProfile = weaver_contracts::decode(include_bytes!(
        "../../../prod/policies/provider/profile.json"
    ))
    .expect("profile");
    c.bench_function("contracts/profile_commitment", |b| {
        b.iter(|| black_box(profile.digest().expect("profile digest")))
    });
    let mut group = c.benchmark_group("contracts/profile_request_validation");
    for bytes in [128, 16384, 524288] {
        let (_, plan) = fixtures::task_plan(bytes, "https://provider.invalid/v1/chat/completions");
        group.throughput(Throughput::Bytes(plan.body.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(bytes), &plan, |b, p| {
            b.iter(|| {
                black_box(
                    profile
                        .request_facts(black_box(&p.body))
                        .expect("closed request"),
                )
            })
        });
    }
    group.finish();
}
fn source_commitment(c: &mut Criterion) {
    let command = weaver_contracts::SourceRotation {
        operation_id: "source-handoff".into(),
        expected_epoch: 0,
        next: source_fixture::source_identity(1),
    };
    c.bench_function("contracts/source_rotation_commitment", |b| {
        b.iter(|| black_box(command.digest().expect("source command binding")))
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=commitments,profile_contracts,source_commitment}
criterion_main!(benches);
