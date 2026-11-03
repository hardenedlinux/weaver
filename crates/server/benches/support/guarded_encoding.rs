//! Same-image placement control: identical bytes and fresh guards in both arms.
use criterion::{BenchmarkId, Criterion};
use std::{collections::BTreeSet, hint::black_box, time::Duration};
use weaver_contracts::{ProviderEvent, ProviderEventKind};
use weaver_server::{
    encoding::{Frame, encode_frame},
    pb,
};
#[path = "../../../contracts/benches/support/fixtures.rs"]
mod fixtures;
#[path = "../../../policy/benches/support/fixtures.rs"]
mod policy_fixture;
#[path = "../../../ledger/benches/support/provider_store.rs"]
mod stores;

pub fn benchmarks(c: &mut Criterion) {
    let mut group = c.benchmark_group("server/encoding_guard_hold");
    let events = (0..32)
        .map(|sequence| ProviderEvent {
            sequence,
            kind: ProviderEventKind::Delta,
            text: "x".repeat(4096),
            tokens: 0,
        })
        .collect::<Vec<_>>();
    let encode = || {
        encode_frame(Frame {
            target: "primary",
            model: "model-a",
            events: &events,
            encoding: pb::Encoding::ArrowIpc,
        })
        .expect("bounded encoding")
    };
    let expected = encode();
    for (name, inside) in [("inside", true), ("outside", false)] {
        group.bench_with_input(BenchmarkId::from_parameter(name), &inside, |b, &inside| {
            // Custom measurements report only successful transaction holding,
            // not setup, encoder work outside the scope or end-to-end latency.
            b.iter_custom(|iterations| {
                let mut holding = Duration::ZERO;
                for _ in 0..iterations {
                    let (temp, mut ledger, plan) =
                        stores::fresh(128, "https://provider.invalid/v1/chat/completions");
                    ledger.enqueue_provider(&plan).expect("reserve");
                    let permit = ledger
                        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
                        .expect("consume");
                    ledger
                        .dispatch_provider(&permit, || Ok(()))
                        .expect("request burn");
                    let release = ledger
                        .prepare_provider_release(&permit, "events", "arrow", 32)
                        .expect("release burn");
                    assert_eq!(release.first_sequence(), 0);
                    let mut prepared = if inside { None } else { Some(encode()) };
                    let before = ledger.transaction_timings();
                    let frame = ledger
                        .release_provider(&permit, release, "arrow", |first| {
                            assert_eq!(first, 0);
                            Ok(if inside {
                                encode()
                            } else {
                                prepared.take().expect("one owned frame")
                            })
                        })
                        .expect("fresh per-row guard");
                    let observed = ledger.transaction_timings().since(before);
                    assert_eq!(observed.transaction_hold.attempts, 1);
                    assert_eq!(observed.provider_queue.attempts, 1);
                    holding = holding
                        .saturating_add(Duration::from_nanos(observed.transaction_hold.nanos));
                    assert_eq!(frame, expected, "placement changed bytes");
                    assert_eq!(ledger.held("f").expect("hold"), 4);
                    black_box(frame);
                    ledger.close().expect("clean session");
                    drop(temp);
                }
                holding
            })
        });
    }
    group.finish();
}
