// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Typed contract fixtures; no provider traffic or authorization receipt.
#[path = "../../../contracts/benches/support/fixtures.rs"]
mod contracts;
use weaver_governance::{SourceData, SourceSelection};
pub fn source() -> SourceData {
    let (mut task, plan) =
        contracts::task_plan(128, "https://provider.invalid/v1/chat/completions");
    let mut next = plan.clone();
    next.node = "next".into();
    task.nodes.push(next.node.clone());
    task.body_digests
        .insert(next.node.clone(), weaver_contracts::body_digest(&next.body));
    task.node_cost_bounds.insert(next.node.clone(), 4);
    task.stream_contracts
        .insert(next.node.clone(), next.digest().expect("next"));
    SourceData {
        governance: SourceSelection {
            schema: "agentic-ai-lab.loop-governor.v1".into(),
            family: "f".into(),
            open_nodes: vec!["infer".into(), "next".into()],
        },
        tasks: vec![task],
        plans: vec![plan, next],
        publication: weaver_contracts::Publication {
            operation_id: "source".into(),
            expected_revision: Some(0),
            fence: 1,
            policy: "forbid(principal,action,resource);".into(),
            schema: include_str!("../../../../prod/policies/provider/schema.json").into(),
        },
    }
}
