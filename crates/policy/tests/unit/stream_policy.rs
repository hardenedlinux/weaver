// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use weaver_contracts::{MessageRule, StreamContract, StreamMessage, Task, body_digest};
use weaver_policy::{StreamCheck, authorize_stream};
const POLICY: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../prod/policies/streaming/stream.cedar"
));
const SCHEMA: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../prod/policies/streaming/schema.json"
));

#[test]
fn specification_derived_policy_is_typed_and_constrains_actual_range_facts() {
    weaver_policy::validate_typed(POLICY, SCHEMA).expect("strict Cedar schema");
    let c = StreamContract {
        family: "f".into(),
        node: "emit".into(),
        profile: "p".into(),
        target: "t".into(),
        input_digest: body_digest("input"),
        destination: "tls://localhost:443".into(),
        messages: vec![MessageRule {
            id: "m0".into(),
            max_bytes: 8,
            cost_bound: 4,
        }],
    };
    let t = Task {
        provider_profile: None,
        family: "f".into(),
        principal: "alice".into(),
        profile: "p".into(),
        nodes: vec!["emit".into()],
        targets: vec!["t".into()],
        endpoints: [("t".into(), "https://provider.invalid/".into())].into(),
        body_digests: [("emit".into(), c.input_digest.clone())].into(),
        node_cost_bounds: [("emit".into(), 4)].into(),
        stream_contracts: [("emit".into(), c.digest().expect("manifest"))].into(),
        models: vec!["m".into()],
        budget: 4,
    };
    let message = StreamMessage {
        family: "f".into(),
        node: "emit".into(),
        message: "m0".into(),
        contract_digest: c.digest().expect("digest"),
        payload: "abcdefgh".into(),
        ceiling: 4,
        revision: 0,
        fence: 1,
    }
    .binding()
    .expect("binding");
    let check = |offset, length| StreamCheck {
        contract: &c,
        message: &message,
        action: "writeRange",
        offset,
        length,
        revision: 0,
        fence: 1,
    };
    assert!(authorize_stream(POLICY, &t, check(0, 4)).is_ok());
    assert!(authorize_stream(POLICY, &t, check(5, 4)).is_err());
    assert!(authorize_stream(POLICY, &t, check(0, 0)).is_err());
    let mut stranger = t.clone();
    stranger.principal = "bob".into();
    assert!(authorize_stream(POLICY, &stranger, check(0, 4)).is_err());
    let mut replaced = t.clone();
    replaced.stream_contracts.clear();
    assert!(authorize_stream(POLICY, &replaced, check(0, 4)).is_err());
    assert!(
        weaver_policy::validate_typed(
            "permit(principal,action,resource) when { context.nonexistent == 1 };",
            SCHEMA
        )
        .is_err()
    );
}
