// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{
    MAX_PROVIDER_TURN_BYTES, ProviderToolCall, ProviderTurnEvent, ProviderTurnIdentity,
    ProviderTurnPayload, ProviderTurnUsage,
};

fn terminal() -> ProviderTurnEvent {
    ProviderTurnEvent {
        version: 1,
        metadata: None,
        payload: ProviderTurnPayload::Finished {
            reason: "completed".into(),
            identity: Some(ProviderTurnIdentity {
                id: "response-1".into(),
                model: "fixture".into(),
            }),
            usage: Some(ProviderTurnUsage {
                input_tokens: 10,
                output_tokens: 2,
                categories: Some(super::ProviderTokenCategories {
                    ordinary_input: 4,
                    cache_read_input: 4,
                    cache_write_input: 2,
                    output: 2,
                }),
            }),
            tool_calls: vec![ProviderToolCall {
                id: "call-1".into(),
                name: "read".into(),
                arguments: serde_json::json!({"path":"file"}),
            }],
            responses_output: Some(vec![
                serde_json::json!({"type":"reasoning","encrypted_content":"opaque"}),
            ]),
            anthropic_output: None,
        },
    }
}

#[test]
fn rich_terminal_round_trip_binds_continuation_and_tools() {
    let event = terminal();
    assert!(event.is_terminal());
    let bytes = event.encode().unwrap();
    assert_eq!(ProviderTurnEvent::decode(&bytes).unwrap(), event);
    let original = crate::body_digest(std::str::from_utf8(&bytes).unwrap());
    let mut changed = event;
    if let ProviderTurnPayload::Finished {
        responses_output, ..
    } = &mut changed.payload
    {
        *responses_output = Some(vec![serde_json::json!({"encrypted_content":"changed"})]);
    }
    assert_ne!(
        original,
        crate::body_digest(std::str::from_utf8(&changed.encode().unwrap()).unwrap())
    );
}

#[test]
fn rich_contract_rejects_version_duplicates_and_oversize() {
    assert!(
        ProviderTurnEvent::decode(
            br#"{"version":1,"version":1,"payload":{"kind":"text","text":"x"}}"#
        )
        .is_err()
    );
    let mut event = terminal();
    event.version = 2;
    assert!(event.encode().is_err());
    let event = ProviderTurnEvent {
        version: 1,
        metadata: None,
        payload: ProviderTurnPayload::Thinking {
            text: "x".repeat(MAX_PROVIDER_TURN_BYTES),
        },
    };
    assert!(event.encode().is_err());
    assert!(ProviderTurnEvent::decode(&vec![b' '; MAX_PROVIDER_TURN_BYTES + 1]).is_err());
}

#[test]
fn rich_contract_rejects_duplicate_tools_and_incomplete_finish() {
    let mut event = terminal();
    if let ProviderTurnPayload::Finished { tool_calls, .. } = &mut event.payload {
        tool_calls.push(tool_calls[0].clone());
    }
    assert!(event.encode().is_err());
    let mut event = terminal();
    if let ProviderTurnPayload::Finished { reason, .. } = &mut event.payload {
        *reason = "length".into();
    }
    assert!(event.encode().is_err());
}

#[test]
fn debug_does_not_disclose_thinking_tool_arguments_or_continuation() {
    let event = terminal();
    let printed = format!("{event:?}");
    assert!(!printed.contains("opaque"));
    assert!(!printed.contains("file"));
    let thinking = ProviderTurnPayload::Thinking {
        text: "hidden-thinking".into(),
    };
    assert!(!format!("{thinking:?}").contains("hidden-thinking"));
}

#[test]
fn category_changes_affect_the_released_frame_commitment_and_mismatches_are_rejected() {
    let mut changed = terminal();
    let original = crate::ProviderEvent {
        sequence: 0,
        kind: crate::ProviderEventKind::Turn(Box::new(changed.clone())),
        text: String::new(),
        tokens: 0,
    };
    if let ProviderTurnPayload::Finished { usage, .. } = &mut changed.payload {
        let categories = usage.as_mut().unwrap().categories.as_mut().unwrap();
        categories.ordinary_input -= 1;
        categories.cache_read_input += 1;
    }
    changed.encode().unwrap();
    let other = crate::ProviderEvent {
        kind: crate::ProviderEventKind::Turn(Box::new(changed.clone())),
        ..original.clone()
    };
    assert_ne!(
        crate::body_digest(&serde_json::to_string(&[original]).unwrap()),
        crate::body_digest(&serde_json::to_string(&[other]).unwrap())
    );
    if let ProviderTurnPayload::Finished { usage, .. } = &mut changed.payload {
        usage.as_mut().unwrap().categories.as_mut().unwrap().output += 1;
    }
    assert!(changed.encode().is_err());
}

fn positioned(index: u64) -> ProviderTurnEvent {
    ProviderTurnEvent {
        version: 1,
        metadata: Some(super::ProviderTurnMetadata {
            identity: None,
            usage: None,
            position: Some(super::ProviderTurnPosition::Responses {
                item_id: "message-1".into(),
                output_index: 0,
                content_index: index,
            }),
            control: None,
        }),
        payload: ProviderTurnPayload::Text {
            text: "same-text".into(),
        },
    }
}

#[test]
fn controls_require_bounded_closed_metadata_and_hide_opaque_signatures_in_debug() {
    let mut event = positioned(0);
    event.payload = ProviderTurnPayload::Control;
    event.metadata = None;
    assert!(event.encode().is_err());
    assert!(positioned(64).encode().is_err());
    let mut value = serde_json::to_value(positioned(0)).unwrap();
    value["metadata"]["tool_arguments"] = serde_json::json!({"private":"partial"});
    assert!(ProviderTurnEvent::decode(&serde_json::to_vec(&value).unwrap()).is_err());
    event.metadata = Some(super::ProviderTurnMetadata {
        identity: None,
        usage: None,
        position: None,
        control: Some(super::ProviderTurnControl::AnthropicStop {
            index: 0,
            block_kind: super::ProviderTurnBlockKind::Thinking,
            signature: Some("opaque-signature".into()),
        }),
    });
    assert_eq!(
        ProviderTurnEvent::decode(&event.encode().unwrap()).unwrap(),
        event
    );
    assert!(!format!("{event:?}").contains("opaque-signature"));
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config {cases:64,rng_seed:proptest::test_runner::RngSeed::Fixed(293),..Default::default()})]
    #[test]
    fn coordinate_changes_bind_the_release_even_when_text_is_identical(index in 0u64..63) {
        let original=positioned(index);
        let changed=positioned(index+1);
        proptest::prop_assert_eq!(ProviderTurnEvent::decode(&original.encode().unwrap()).unwrap(),original.clone());
        proptest::prop_assert_ne!(crate::body_digest(&serde_json::to_string(&original).unwrap()),crate::body_digest(&serde_json::to_string(&changed).unwrap()));
        proptest::prop_assert_eq!(&original.payload,&changed.payload);
        proptest::prop_assert!(!original.is_terminal());
    }
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(128))]
    #[test]
    fn opaque_continuation_survives_the_versioned_contract(content in "[a-zA-Z0-9+/=]{0,512}") {
        let mut event = terminal();
        if let ProviderTurnPayload::Finished { responses_output, .. } = &mut event.payload {
            *responses_output = Some(vec![serde_json::json!({"type":"reasoning", "encrypted_content":content})]);
        }
        let encoded = event.encode().unwrap();
        proptest::prop_assert_eq!(ProviderTurnEvent::decode(&encoded).unwrap(), event);
    }
}
