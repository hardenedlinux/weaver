// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use criterion::{Criterion, criterion_group, criterion_main};
use std::hint::black_box;
use weaver_telemetry::{Metrics, Signal};

fn telemetry(c: &mut Criterion) {
    let metrics = Metrics::default();
    let mut group = c.benchmark_group("telemetry/local");
    group.sample_size(30);
    group.warm_up_time(std::time::Duration::from_secs(1));
    group.measurement_time(std::time::Duration::from_secs(2));
    group.bench_function("record", |b| {
        b.iter(|| metrics.record(black_box(Signal::ResponseFramesQueued)))
    });
    group.bench_function("snapshot", |b| b.iter(|| black_box(metrics.snapshot())));
    group.finish();
}
criterion_group!(benches, telemetry);
criterion_main!(benches);
