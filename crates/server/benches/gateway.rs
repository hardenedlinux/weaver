use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use prost::Message;
use std::{hint::black_box, time::Duration};
use weaver_contracts::{ProviderEvent, ProviderEventKind};
use weaver_server::{
    encoding::{Frame, encode_frame},
    pb,
};
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
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=frame_encoding}
criterion_main!(benches);
