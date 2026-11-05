// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Matched same-process old JSON vs official literal Context construction.
use crate::{
    ProviderCheck, fixtures, literal_context::ProviderContext, reference_context::JsonContext,
};
use criterion::Criterion;
use std::hint::black_box;
use weaver_contracts::{DomainStamp, DomainView};

pub fn contexts(c: &mut Criterion) {
    let (task, plan) = fixtures::task_plan(128, "https://provider.invalid/v1/chat/completions");
    let facts = plan.binding(&task).expect("binding").expect("profile");
    let native =
        ProviderContext::capture(&task, &plan, &plan.routes[0], &facts).expect("native context");
    let reference = JsonContext::capture(&task, &plan, &plan.routes[0]);
    let domains = DomainView {
        family: "f".into(),
        canonical_family: "f".into(),
        stamp: DomainStamp {
            task_key: "task".into(),
            origin: "origin".into(),
            budget_root: "budget".into(),
            history_root: "history".into(),
            budget_epoch: 1,
            history_epoch: 1,
        },
        held: 4,
        budget_limit: 8,
        history_count: 2,
    };
    for include in [false, true] {
        let suffix = if include { "shared" } else { "local" };
        c.bench_function(&format!("policy/context_json_{suffix}"), |b| {
            b.iter(|| {
                black_box(
                    reference
                        .current(&ProviderCheck {
                            action: "emitProvider",
                            sequence: black_box(1),
                            format: "protobuf",
                            domains: if include {
                                Some(black_box(&domains))
                            } else {
                                None
                            },
                        })
                        .expect("JSON context"),
                )
            })
        });
        c.bench_function(&format!("policy/context_literal_{suffix}"), |b| {
            b.iter(|| {
                black_box(
                    native
                        .current(&ProviderCheck {
                            action: "emitProvider",
                            sequence: black_box(1),
                            format: "protobuf",
                            domains: if include {
                                Some(black_box(&domains))
                            } else {
                                None
                            },
                        })
                        .expect("literal context"),
                )
            })
        });
    }
}
