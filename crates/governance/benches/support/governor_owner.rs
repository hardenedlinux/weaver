// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Finite warm owner profile of the existing source lane, without effect authority.
use std::{
    num::NonZeroUsize,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{Barrier, oneshot};
use weaver_governance::{
    Derivation, DerivationOutput, GovernorCut, GovernorTopology, SchemeCompiler, SourceClient,
    source_lane,
};
#[allow(unsafe_code)]
#[path = "governor_usage.rs"]
mod usage;

const WAVES: usize = 32;
const WORKERS: usize = 4;
const EXPECTED: [&[&str]; 4] = [
    ["fork-a", "fork-b"].as_slice(),
    ["inner-finish"].as_slice(),
    ["finish"].as_slice(),
    &[],
];

fn topology() -> Arc<GovernorTopology> {
    // The topology and ordering match runNestedSession's real Scheme fixture.
    Arc::new(GovernorTopology {
        nodes: [
            "infer",
            "gate",
            "next",
            "side",
            "fork-a",
            "fork-b",
            "inner-finish",
            "outer-skip",
            "finish",
        ]
        .map(str::to_owned)
        .into(),
        edges: [
            ("finish", "inner-finish"),
            ("finish", "outer-skip"),
            ("fork-a", "side"),
            ("fork-b", "side"),
            ("gate", "infer"),
            ("inner-finish", "fork-a"),
            ("inner-finish", "fork-b"),
            ("inner-finish", "next"),
            ("next", "gate"),
            ("outer-skip", "infer"),
            ("side", "gate"),
        ]
        .map(|(a, b)| (a.into(), b.into()))
        .into(),
        choice_arms: vec![],
        choice_join: vec![],
        nested_selectors: [["gate", "next", "side"], ["infer", "gate", "outer-skip"]]
            .map(|row| row.map(str::to_owned))
            .into(),
    })
}

fn cut(topology: &Arc<GovernorTopology>, phase: usize) -> GovernorCut {
    let mut complete: Vec<String> = ["infer", "gate", "side"].map(str::to_owned).into();
    if phase != 0 {
        complete.extend(["fork-a", "fork-b"].map(str::to_owned));
    }
    if phase == 2 {
        complete.push("inner-finish".into());
    }
    GovernorCut {
        topology: topology.clone(),
        available: topology
            .nodes
            .iter()
            .filter(|node| phase != 3 || *node != "fork-b")
            .cloned()
            .collect(),
        pending: topology
            .nodes
            .iter()
            .filter(|node| !complete.contains(node))
            .cloned()
            .collect(),
        complete,
        choice_result: vec![],
        choice_decided: vec![],
        nested_results: vec![
            ("infer".into(), "left".into()),
            ("gate".into(), "right".into()),
        ],
        nested_decisions: vec![
            ("infer".into(), "left".into()),
            ("gate".into(), "right".into()),
        ],
    }
}

fn phase(input: &Derivation) -> usize {
    let Derivation::Governor(cut) = input else {
        panic!("only Governor cuts in this profile")
    };
    match (cut.complete.len(), cut.available.len()) {
        (3, 9) => 0,
        (5, 9) => 1,
        (6, 9) => 2,
        (5, 8) => 3,
        _ => panic!("unexpected frozen snapshot"),
    }
}

fn verify(output: DerivationOutput, topology: &GovernorTopology, phase: usize) {
    let mut nodes = match output {
        DerivationOutput::Nodes(nodes) => nodes,
        DerivationOutput::Source(_) => panic!("source reply cannot advance a Governor"),
        DerivationOutput::Indices(indices) => indices
            .into_iter()
            .map(|i| topology.nodes.get(i).expect("bound index").clone())
            .collect(),
    };
    nodes.sort_unstable();
    assert_eq!(nodes, EXPECTED[phase], "wrong candidates for phase {phase}");
}

struct OwnerSample {
    wave: usize,
    phase: usize,
    started: Instant,
    finished: Instant,
    usage: Option<usage::Delta>,
}
struct RequestSample {
    wave: usize,
    phase: usize,
    submitted: Instant,
    received: Instant,
}

async fn wave(
    client: &SourceClient,
    topology: &Arc<GovernorTopology>,
    wave: usize,
) -> Vec<RequestSample> {
    let barrier = Arc::new(Barrier::new(WORKERS + 1));
    let mut jobs = Vec::with_capacity(WORKERS);
    for phase in 0..WORKERS {
        let (client, topology, barrier) = (client.clone(), topology.clone(), barrier.clone());
        let input = cut(&topology, phase);
        jobs.push(tokio::spawn(async move {
            barrier.wait().await;
            let submitted = Instant::now();
            let output = client.derive(input).await.expect("owner derivation");
            let received = Instant::now();
            verify(output, &topology, phase);
            RequestSample {
                wave,
                phase,
                submitted,
                received,
            }
        }));
    }
    barrier.wait().await;
    let mut samples = Vec::with_capacity(WORKERS);
    for job in jobs {
        samples.push(job.await.expect("request task"));
    }
    samples
}

fn ns(duration: Duration) -> u64 {
    duration.as_nanos().try_into().expect("bounded interval")
}

pub(super) fn run() {
    assert!(
        std::env::var_os("WEAVER_TEST_GOVERNOR_TIMING").is_none(),
        "verbose timing changes the measured path"
    );
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(WORKERS)
        .max_blocking_threads(1)
        .enable_all()
        .build()
        .expect("four-worker runtime");
    let topology = topology();
    let (client, inbox) = source_lane(NonZeroUsize::new(WORKERS).expect("capacity"));
    let (ready, prepared) = oneshot::channel();
    let graph = topology.clone();
    let observe_usage = std::env::var("WEAVER_TEST_GOVERNOR_USAGE").as_deref() == Ok("1");
    let owner = runtime.spawn_blocking(move || {
        let started = Instant::now();
        let mut compiler = SchemeCompiler::initialize().expect("approved linked application");
        verify(
            compiler.derive(&cut(&graph, 0)).expect("preopen"),
            &graph,
            0,
        );
        ready
            .send(ns(started.elapsed()))
            .expect("readiness receiver");
        let mut samples = Vec::with_capacity(WAVES * WORKERS);
        let mut waves = [0; WORKERS];
        inbox.run_with_cancellable_governor(
            compiler,
            |compiler, original, cancel| compiler.compile_cancellable(original, cancel),
            |compiler, input| {
                let phase = phase(input);
                // Existing SDK counters allocate no Scheme objects. Keep the
                // observation outside the derive clock, within request latency.
                let before = observe_usage.then(usage::read);
                let started = Instant::now();
                let result = compiler.evaluate(input);
                let finished = Instant::now();
                let usage = before.map(|before| usage::read().delta(before));
                samples.push(OwnerSample {
                    wave: waves[phase],
                    phase,
                    started,
                    finished,
                    usage,
                });
                waves[phase] += 1;
                result
            },
        );
        samples
    });
    let readiness_ns = runtime.block_on(async {
        tokio::time::timeout(Duration::from_secs(12), prepared)
            .await
            .expect("owner readiness deadline")
            .expect("prepared owner")
    });
    let requests = runtime.block_on(async {
        tokio::time::timeout(Duration::from_secs(120), async {
            let mut samples = Vec::with_capacity(WAVES * WORKERS);
            for round in 0..WAVES {
                samples.extend(wave(&client, &topology, round).await);
            }
            samples
        })
        .await
        .expect("finite measurement deadline")
    });
    client.close();
    let draining = Instant::now();
    let samples = runtime.block_on(async {
        tokio::time::timeout(Duration::from_secs(15), owner)
            .await
            .expect("natural owner drain deadline")
            .expect("owner joined")
    });
    let drain_ns = ns(draining.elapsed());
    assert_eq!(samples.len(), WAVES * WORKERS);
    let rows = samples.into_iter().map(|owner| {
        let request = requests.iter().find(|r| r.wave == owner.wave && r.phase == owner.phase).expect("unique request");
        assert!(request.submitted <= owner.started && owner.started <= owner.finished && owner.finished <= request.received);
        serde_json::json!({"wave": owner.wave, "phase": owner.phase, "queue_ns": ns(owner.started - request.submitted), "derive_ns": ns(owner.finished - owner.started), "reply_ns": ns(request.received - owner.finished), "total_ns": ns(request.received - request.submitted), "usage": owner.usage})
    }).collect::<Vec<_>>();
    println!(
        "{}",
        serde_json::json!({"profile": "governor-owner-warm", "usage_observed": observe_usage, "tokio_workers": WORKERS, "scheme_owners": 1, "queue_capacity": WORKERS, "waves": WAVES, "readiness_ns": readiness_ns, "drain_ns": drain_ns, "samples": rows})
    );
}
