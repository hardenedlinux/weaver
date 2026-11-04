// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use prost::Message;
use std::{hint::black_box, time::Duration};
use weaver_contracts::{ProviderEvent, ProviderEventKind};
use weaver_server::{
    encoding::{Frame, encode_frame},
    pb,
};
#[cfg(feature = "arrow")]
#[path = "support/guarded_encoding.rs"]
mod guarded_encoding;
fn guarded_encoding(c: &mut Criterion) {
    #[cfg(feature = "arrow")]
    guarded_encoding::benchmarks(c);
    #[cfg(not(feature = "arrow"))]
    let _ = c;
}
fn frame_encoding(c: &mut Criterion) {
    let mut group = c.benchmark_group("server/response_encoding");
    for rows in [1, 32] {
        let events: Vec<_> = (0..rows)
            .map(|sequence| ProviderEvent {
                sequence,
                kind: ProviderEventKind::Delta,
                text: "governed token".into(),
                tokens: 0,
            })
            .collect();
        group.throughput(Throughput::Elements(rows));
        group.bench_with_input(
            BenchmarkId::new("protobuf_frames", rows),
            &events,
            |b, events| {
                b.iter(|| {
                    let mut bytes = 0;
                    for event in events {
                        bytes += encode_frame(Frame {
                            target: "primary",
                            model: "model-a",
                            events: std::slice::from_ref(event),
                            encoding: pb::Encoding::Protobuf,
                        })
                        .expect("protobuf frame")
                        .encode_to_vec()
                        .len();
                    }
                    black_box(bytes)
                })
            },
        );
        #[cfg(feature = "arrow")]
        group.bench_with_input(
            BenchmarkId::new("arrow_batch", rows),
            &events,
            |b, events| {
                b.iter(|| {
                    black_box(
                        encode_frame(Frame {
                            target: "primary",
                            model: "model-a",
                            events,
                            encoding: pb::Encoding::ArrowIpc,
                        })
                        .expect("Arrow frame")
                        .encode_to_vec(),
                    )
                })
            },
        );
    }
    group.finish();
}
fn source_identity(c: &mut Criterion) {
    let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()]).expect("certificate");
    let credential = weaver_contracts::body_digest("source role");
    c.bench_function("server/source_certificate_spki_identity", |b| {
        b.iter(|| {
            black_box(
                weaver_server::source_certificate_identity(
                    cert.cert.der().as_ref(),
                    credential.clone(),
                )
                .expect("exact DER/SPKI identity"),
            )
        })
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=guarded_encoding,frame_encoding,source_identity}
criterion_main!(benches);
