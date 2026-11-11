// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use criterion::{Criterion, criterion_group, criterion_main};
use std::{hint::black_box, time::Duration};
use weaver_llm::{Message, Options, Protocol, Request, Role};

fn request_encoding(c: &mut Criterion) {
    let messages = [Message {
        role: Role::User,
        content: "Explain the budget of this provider request.".to_owned(),
        images: Vec::new(),
        name: None,
        tool_call_id: None,
        tool_calls: Vec::new(),
        responses_output: None,
    }];
    let request = Request {
        model: "gpt-example",
        messages: &messages,
        options: &Options::default(),
    };
    let mut group = c.benchmark_group("llm/request");
    group.sample_size(30);
    group.warm_up_time(Duration::from_secs(1));
    group.measurement_time(Duration::from_secs(2));
    group.bench_function("openai-text", |b| {
        b.iter(|| black_box(black_box(&request).encode(Protocol::OpenAi, false)))
    });
    group.finish();
}
criterion_group!(benches, request_encoding);
criterion_main!(benches);
