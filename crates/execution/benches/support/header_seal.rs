//! Finite same-image ABBA: isolate header latency from real ledger hold counters.
use super::{Provider, ProviderExecution, ProviderTransport, Sink, execute_provider, stores};
use serde::Serialize;
use std::{collections::BTreeMap, sync::atomic::Ordering, time::Instant};
#[derive(Serialize)]
struct Sample {
    block: usize,
    slot: usize,
    delayed: bool,
    optimized: bool,
    cpus: usize,
    wall_ns: u64,
    held: u64,
    events: usize,
    calls: usize,
    timings: weaver_ledger::persistence::TransactionTimings,
}
pub(super) fn run() {
    let provider = Provider::start();
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "benchmark-key".into())]),
        Some(provider.pem.as_bytes()),
        provider.runtime.handle().clone(),
    )
    .expect("transport");
    for block in 0..6 {
        for (slot, delayed) in [false, true, true, false].into_iter().enumerate() {
            provider
                .delay
                .store(if delayed { 30 } else { 0 }, Ordering::SeqCst);
            let (_directory, mut ledger, plan) = stores::fresh(128, &provider.endpoint);
            let before = ledger.transaction_timings();
            let mut sink = Sink { events: 0 };
            let begin = Instant::now();
            execute_provider(
                &mut ledger,
                ProviderExecution {
                    plan: &plan,
                    transport: &transport,
                    format: "protobuf",
                    batch_rows: 1,
                },
                &mut sink,
            )
            .expect("actual provider SSE");
            let wall_ns = u64::try_from(begin.elapsed().as_nanos()).expect("duration");
            let timings = ledger.transaction_timings().since(before);
            let calls = provider.calls.load(Ordering::SeqCst);
            assert_eq!(calls, block * 4 + slot + 1);
            assert_eq!(sink.events, 3);
            assert_eq!(ledger.held("f").expect("held"), 4);
            assert!(
                execute_provider(
                    &mut ledger,
                    ProviderExecution {
                        plan: &plan,
                        transport: &transport,
                        format: "protobuf",
                        batch_rows: 1
                    },
                    &mut sink
                )
                .is_err()
            );
            assert_eq!(provider.calls.load(Ordering::SeqCst), calls);
            let sample = Sample {
                block,
                slot,
                delayed,
                optimized: !cfg!(debug_assertions),
                cpus: std::thread::available_parallelism().expect("cpus").get(),
                wall_ns,
                held: 4,
                events: sink.events,
                calls,
                timings,
            };
            println!(
                "weaver-header-seal {}",
                serde_json::to_string(&sample).expect("evidence")
            );
            ledger.close().expect("natural ledger cleanup");
        }
    }
}
