use criterion::{BatchSize, BenchmarkId, Criterion, criterion_group, criterion_main};
use std::{collections::BTreeSet, hint::black_box, time::Duration};
#[path = "support/fixtures.rs"]
mod exposure;
#[path = "../../contracts/benches/support/fixtures.rs"]
mod fixtures;
#[path = "support/mvcc.rs"]
mod mvcc;
#[path = "support/task_origins.rs"]
mod origins;
#[path = "../../policy/benches/support/fixtures.rs"]
mod policy_fixture;
#[path = "../../policy/tests/support/publication_replay.rs"]
mod replay_fixture;
#[path = "../../policy/tests/support/publication_revision.rs"]
mod revision_fixture;
#[path = "../../contracts/benches/support/source_authority.rs"]
mod source_fixture;
#[path = "support/provider_store.rs"]
mod stores;
fn concurrent_admission(c: &mut Criterion) {
    let mut admission = c.benchmark_group("ledger/concurrent_family_pair");
    for (name, journal) in [
        ("wal", weaver_ledger::persistence::Journal::Wal),
        ("mvcc", weaver_ledger::persistence::Journal::Mvcc),
    ] {
        admission.bench_function(name, |b| {
            b.iter_batched(
                || mvcc::fresh(journal),
                |fixture| fixture.reserve(),
                BatchSize::PerIteration,
            )
        });
    }
    admission.finish();
    let mut final_use = c.benchmark_group("ledger/final_family_pair");
    for (name, journal, serialized, shared) in [
        ("wal", weaver_ledger::persistence::Journal::Wal, false, 0),
        (
            "mvcc-serial",
            weaver_ledger::persistence::Journal::Mvcc,
            true,
            0,
        ),
        (
            "mvcc-parallel",
            weaver_ledger::persistence::Journal::Mvcc,
            false,
            0,
        ),
        (
            "mvcc-shared-budget",
            weaver_ledger::persistence::Journal::Mvcc,
            false,
            1,
        ),
        (
            "mvcc-shared-history",
            weaver_ledger::persistence::Journal::Mvcc,
            false,
            2,
        ),
    ] {
        final_use.bench_function(name, |b| {
            b.iter_batched(
                || mvcc::fresh_domains(journal, shared).prepare(),
                |ready| ready.send(serialized),
                BatchSize::PerIteration,
            )
        });
    }
}
fn durable_operations(c: &mut Criterion) {
    c.bench_function("ledger/fresh_admission", |b| {
        b.iter_batched(
            || stores::fresh(128, "https://provider.invalid/v1/chat/completions"),
            |(temp, mut ledger, plan)| {
                let receipt = ledger.enqueue_provider(&plan).expect("admission");
                assert_eq!(receipt.reserved, 4);
                black_box((temp, ledger, receipt))
            },
            BatchSize::PerIteration,
        )
    });
    c.bench_function("ledger/consume_and_dispatch_burn", |b| {
        b.iter_batched(
            || {
                let (temp, mut ledger, plan) =
                    stores::fresh(128, "https://provider.invalid/v1/chat/completions");
                ledger.enqueue_provider(&plan).expect("queue");
                (temp, ledger)
            },
            |(temp, mut ledger)| {
                let permit = ledger
                    .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
                    .expect("consume");
                ledger
                    .dispatch_provider(&permit, || black_box(()))
                    .expect("guarded callback");
                assert_eq!(ledger.held("f").expect("hold"), 4);
                black_box((temp, ledger))
            },
            BatchSize::PerIteration,
        )
    });
    let (_temp, mut ledger, plan) =
        stores::fresh(128, "https://provider.invalid/v1/chat/completions");
    ledger.enqueue_provider(&plan).expect("queue");
    c.bench_function("ledger/idempotent_admission", |b| {
        b.iter(|| {
            let receipt = ledger.enqueue_provider(&plan).expect("same root");
            assert_eq!(receipt.reserved, 4);
            black_box(receipt)
        })
    });
}
fn shared_exposure(c: &mut Criterion) {
    let mut group = c.benchmark_group("ledger/shared_exposure_dispatch");
    for count in [1usize, 8, 64] {
        group.bench_with_input(BenchmarkId::from_parameter(count), &count, |b, &count| {
            b.iter_batched(
                || exposure::family(count),
                |(temp, mut ledger)| {
                    let permit = ledger
                        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
                        .expect("consume");
                    ledger
                        .dispatch_provider(&permit, || black_box(()))
                        .expect("current final use");
                    black_box((temp, ledger))
                },
                BatchSize::PerIteration,
            )
        });
    }
    group.finish();
}
fn original_reservation_bytes(c: &mut Criterion) {
    let mut group = c.benchmark_group("ledger/original_reservation_bytes");
    for (count, bytes) in [
        (1usize, 128usize),
        (8, 128),
        (64, 128),
        (1, 16384),
        (8, 16384),
        (64, 16384),
        (1, 524288),
    ] {
        group.bench_with_input(
            BenchmarkId::new(count.to_string(), bytes),
            &(count, bytes),
            |b, &(count, bytes)| {
                b.iter_batched(
                    || exposure::family_with_body(count, bytes),
                    |(temp, mut ledger)| {
                        let permit = ledger
                            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
                            .expect("consume original");
                        ledger
                            .dispatch_provider(&permit, || black_box(()))
                            .expect("current original amounts");
                        assert_eq!(ledger.held("f").expect("conserved hold"), count as u64 * 4);
                        black_box((temp, ledger))
                    },
                    BatchSize::PerIteration,
                )
            },
        );
    }
    group.finish();
}
fn stream_manifest_guard(c: &mut Criterion) {
    let mut group = c.benchmark_group("ledger/stream_manifest_guard");
    for count in [1usize, 8, 64] {
        group.bench_with_input(BenchmarkId::from_parameter(count), &count, |b, &count| {
            b.iter_batched(
                || exposure::stream(count),
                |(temp, mut ledger, owner)| {
                    let permit = ledger
                        .consume_range(&owner, "m0", 4)
                        .expect("consume range");
                    ledger
                        .write_range(&owner, permit, |_| {
                            weaver_contracts::WriteObservation::Complete
                        })
                        .expect("current manifest guard");
                    assert_eq!(
                        ledger.held("f").expect("retained exposure"),
                        count as u64 * 4
                    );
                    black_box((temp, ledger, owner))
                },
                BatchSize::PerIteration,
            )
        });
    }
    group.finish();
}
fn range_tail_guard(c: &mut Criterion) {
    let mut group = c.benchmark_group("ledger/range_tail_guard");
    for history in [0usize, 8, 64] {
        group.bench_with_input(
            BenchmarkId::from_parameter(history),
            &history,
            |b, &history| {
                b.iter_batched(
                    || {
                        let store = exposure::stream_with_payload(1, history + 1);
                        let (temp, mut ledger, owner) = store;
                        for _ in 0..history {
                            let permit = ledger
                                .consume_range(&owner, "m0", 1)
                                .expect("prefix consumption");
                            ledger
                                .write_range(&owner, permit, |_| {
                                    weaver_contracts::WriteObservation::Complete
                                })
                                .expect("known prefix");
                        }
                        (temp, ledger, owner)
                    },
                    |(temp, mut ledger, owner)| {
                        let permit = ledger
                            .consume_range(&owner, "m0", 1)
                            .expect("indexed tail join");
                        ledger
                            .write_range(&owner, permit, |_| {
                                weaver_contracts::WriteObservation::Complete
                            })
                            .expect("final range");
                        assert_eq!(ledger.held("f").expect("original hold"), 4);
                        black_box((temp, ledger, owner))
                    },
                    BatchSize::PerIteration,
                )
            },
        );
    }
    group.finish();
}
fn publication_operations(c: &mut Criterion) {
    let change = weaver_contracts::Publication {
        operation_id: "measured".into(),
        expected_revision: Some(0),
        fence: 1,
        policy: policy_fixture::POLICY.into(),
        schema: policy_fixture::SCHEMA.into(),
    };
    c.bench_function("ledger/publication_stage_and_decide", |b| {
        b.iter_batched(
            || stores::fresh(128, "https://provider.invalid/v1/chat/completions"),
            |(temp, mut ledger, _)| {
                let key = ledger.stage_authority(&change).expect("durable barrier");
                let receipt = ledger
                    .publish_authority(&change)
                    .expect("atomic resolution");
                assert_eq!(key.digest, receipt.digest);
                assert_eq!(
                    receipt.outcome,
                    weaver_contracts::PublicationOutcome::Committed
                );
                black_box((temp, ledger, receipt))
            },
            BatchSize::PerIteration,
        )
    });
    c.bench_function("ledger/publication_atomic_commit", |b| {
        b.iter_batched(
            || stores::fresh(128, "https://provider.invalid/v1/chat/completions"),
            |(temp, mut ledger, _)| {
                let receipt = ledger
                    .publish_authority(&change)
                    .expect("atomic publication");
                assert_eq!(
                    receipt.outcome,
                    weaver_contracts::PublicationOutcome::Committed
                );
                black_box((temp, ledger, receipt))
            },
            BatchSize::PerIteration,
        )
    });
    let (_temp, mut ledger, _) = stores::fresh(128, "https://provider.invalid/v1/chat/completions");
    let receipt = ledger
        .publish_authority(&change)
        .expect("original decision");
    c.bench_function("ledger/publication_exact_replay", |b| {
        b.iter(|| {
            assert_eq!(
                black_box(ledger.publish_authority(&change).expect("replay")),
                receipt
            )
        })
    });
    let key = weaver_contracts::PublicationKey {
        operation_id: change.operation_id,
        digest: receipt.digest.clone(),
    };
    c.bench_function("ledger/publication_historical_lookup", |b| {
        b.iter(|| {
            assert_eq!(
                black_box(ledger.publication_receipt(&key).expect("lookup")),
                Some(receipt.clone())
            )
        })
    });
}
fn reviewed_publication(c: &mut Criterion) {
    let change = weaver_contracts::Publication {
        operation_id: "reviewed-benchmark".into(),
        expected_revision: Some(0),
        fence: 1,
        policy: policy_fixture::POLICY.into(),
        schema: policy_fixture::SCHEMA.into(),
    };
    c.bench_function("ledger/reviewed_publication_register_and_commit", |b| {
        b.iter_batched(
            || {
                let (temp, mut ledger, _) =
                    stores::fresh(128, "https://provider.invalid/v1/chat/completions");
                let publication = ledger
                    .stage_reviewed_authority(&change)
                    .expect("review latch");
                let parent = ledger
                    .required_review_parent(&publication)
                    .expect("independent parent");
                (
                    temp,
                    ledger,
                    weaver_contracts::PublicationReview {
                        publication,
                        parent,
                        artifact: "trusted-host-benchmark".repeat(1024),
                    },
                )
            },
            |(temp, mut ledger, review)| {
                ledger
                    .register_approved_review(&review)
                    .expect("exact local registration");
                let receipt = ledger
                    .publish_authority(&change)
                    .expect("guarded final CAS");
                assert_eq!(
                    receipt.outcome,
                    weaver_contracts::PublicationOutcome::Committed
                );
                black_box((temp, ledger, receipt))
            },
            BatchSize::PerIteration,
        )
    });
}
fn replay_checked_publication(c: &mut Criterion) {
    let (change, review, _) = replay_fixture::fixture();
    c.bench_function("ledger/spec_replay_register_and_commit", |b| {
        b.iter_batched(
            || {
                let temp = tempfile::tempdir().expect("directory");
                let mut ledger =
                    weaver_ledger::Ledger::open(temp.path().join("replay.db")).expect("store");
                ledger
                    .stage_reviewed_authority(&change)
                    .expect("original latch");
                (temp, ledger)
            },
            |(temp, mut ledger)| {
                ledger
                    .register_replay_checked_review(&change, &review)
                    .expect("native evidence check and registration");
                let receipt = ledger
                    .publish_authority(&change)
                    .expect("original final CAS");
                assert_eq!(
                    receipt.outcome,
                    weaver_contracts::PublicationOutcome::Committed
                );
                black_box((temp, ledger, receipt))
            },
            BatchSize::PerIteration,
        )
    });
    let (change, review, before) = revision_fixture::fixture(replay_fixture::fixture());
    c.bench_function("ledger/spec_parent_bound_revision_registration", |b| {
        b.iter_batched(
            || {
                let temp = tempfile::tempdir().expect("directory");
                let mut ledger =
                    weaver_ledger::Ledger::open(temp.path().join("revision.db")).expect("store");
                ledger
                    .publish_typed(None, &before, &change.schema, 1)
                    .expect("parent");
                ledger
                    .stage_reviewed_authority(&change)
                    .expect("captured parent");
                (temp, ledger)
            },
            |(temp, mut ledger)| {
                ledger
                    .register_replay_checked_review(&change, &review)
                    .expect("checked pair");
                let receipt = ledger.publish_authority(&change).expect("original CAS");
                assert_eq!(
                    receipt.outcome,
                    weaver_contracts::PublicationOutcome::Committed
                );
                black_box((temp, ledger, receipt))
            },
            BatchSize::PerIteration,
        )
    });
}
fn profile_registration(c: &mut Criterion) {
    let (task, _) = fixtures::task_plan(128, "https://provider.invalid/v1/chat/completions");
    c.bench_function("ledger/profile_task_registration", |b| {
        b.iter_batched(
            || {
                let temp = tempfile::tempdir().expect("temporary store");
                let ledger =
                    weaver_ledger::Ledger::open(temp.path().join("profile.db")).expect("ledger");
                (temp, ledger)
            },
            |(temp, mut ledger)| {
                ledger
                    .register_task(&task)
                    .expect("atomic profile and task");
                black_box((temp, ledger))
            },
            BatchSize::PerIteration,
        )
    });
    let mut group = c.benchmark_group("ledger/profile_task_replay");
    for count in [1, 256] {
        let (_temp, mut ledger, plan) =
            stores::fresh(128, "https://provider.invalid/v1/chat/completions");
        for i in 1..count {
            let mut other = task.clone();
            let mut bound = plan.clone();
            other.family = format!("profile-family-{i}");
            bound.family = other.family.clone();
            other
                .stream_contracts
                .insert(bound.node.clone(), bound.digest().expect("binding"));
            ledger
                .register_task(&other)
                .expect("shared profile floor fixture");
        }
        group.bench_with_input(BenchmarkId::from_parameter(count), &count, |b, _| {
            b.iter(|| {
                ledger
                    .register_task(black_box(&task))
                    .expect("exact original replay");
                black_box(())
            })
        });
    }
    group.finish();
}
fn source_authority(c: &mut Criterion) {
    let caller = source_fixture::source_identity(0);
    for additional_tables in [0, 32] {
        c.bench_with_input(
            BenchmarkId::new("ledger/source_empty_store_enrollment", additional_tables),
            &additional_tables,
            |b, &tables| {
                b.iter_batched(
                    || {
                        let temp = tempfile::tempdir().expect("directory");
                        let path = temp.path().join("enrollment.db");
                        let ledger = weaver_ledger::Ledger::open(&path).expect("store");
                        let mut catalog = weaver_ledger::persistence::Session::open(&path)
                            .expect("fixture catalog");
                        let tx = weaver_ledger::persistence::begin(&mut catalog)
                            .expect("fixture transaction");
                        for table in 0..tables {
                            weaver_ledger::persistence::script(
                                &tx,
                                &format!(
                                    "CREATE TABLE extension_{table} (retained INTEGER NOT NULL)"
                                ),
                            )
                            .expect("empty extension table");
                        }
                        tx.commit().expect("fixture catalog complete");
                        (temp, ledger)
                    },
                    |(temp, mut ledger)| {
                        ledger
                            .with_authenticated_source(&caller, |_| Ok(()))
                            .expect("empty-store enrollment");
                        black_box((temp, ledger))
                    },
                    BatchSize::PerIteration,
                )
            },
        );
    }
    let command = weaver_contracts::SourceRotation {
        operation_id: "source-handoff".into(),
        expected_epoch: 0,
        next: source_fixture::source_identity(1),
    };
    c.bench_function("ledger/source_key_handoff", |b| {
        b.iter_batched(
            || {
                let temp = tempfile::tempdir().expect("directory");
                let mut ledger =
                    weaver_ledger::Ledger::open(temp.path().join("source.db")).expect("store");
                ledger
                    .with_authenticated_source(&caller, |_| Ok(()))
                    .expect("enroll outside timing");
                (temp, ledger)
            },
            |(temp, mut ledger)| {
                black_box((
                    ledger
                        .rotate_source_authority(&caller, &command)
                        .expect("atomic source handoff"),
                    temp,
                    ledger,
                ))
            },
            BatchSize::PerIteration,
        )
    });
    let publication = weaver_contracts::Publication {
        operation_id: "source-publication".into(),
        expected_revision: None,
        fence: 1,
        policy: policy_fixture::POLICY.into(),
        schema: policy_fixture::SCHEMA.into(),
    };
    c.bench_function("ledger/source_authenticated_publication", |b| {
        b.iter_batched(
            || {
                let temp = tempfile::tempdir().expect("directory");
                let mut ledger =
                    weaver_ledger::Ledger::open(temp.path().join("source.db")).expect("store");
                ledger
                    .with_authenticated_source(&caller, |_| Ok(()))
                    .expect("enroll outside timing");
                (temp, ledger)
            },
            |(temp, mut ledger)| {
                black_box((
                    ledger
                        .with_authenticated_source(&caller, |l| l.publish_authority(&publication))
                        .expect("fresh source join at final CAS"),
                    temp,
                    ledger,
                ))
            },
            BatchSize::PerIteration,
        )
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=origins::benchmarks,concurrent_admission,durable_operations,shared_exposure,original_reservation_bytes,stream_manifest_guard,range_tail_guard,publication_operations,profile_registration,reviewed_publication,replay_checked_publication,source_authority}
criterion_main!(benches);
