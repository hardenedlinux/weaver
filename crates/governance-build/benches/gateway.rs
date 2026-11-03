// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use criterion::{Criterion, criterion_group, criterion_main};
use std::{hint::black_box, path::Path, time::Duration};
fn staging(c: &mut Criterion) {
    let application = weaver_governance_build::ProgramApplication::approved(
        "operator/gateway/application",
        Path::new("/tmp/approved/application.ss"),
    )
    .expect("application");
    c.bench_function("governance-build/stage_request", |b| {
        b.iter(|| {
            weaver_governance_build::ProgramStageRequest::new(
                black_box(Path::new("/tmp/package")),
                Path::new("/tmp/prefix/lib"),
                Path::new("/tmp/cargo-out/program"),
                &application,
            )
            .expect("paths")
        })
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=staging}
criterion_main!(benches);
