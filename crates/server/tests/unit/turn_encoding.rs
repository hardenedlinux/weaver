// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{arrow, protobuf};
use crate::pb;
use weaver_contracts::{ProviderEvent, ProviderEventKind};
use weaver_contracts::{ProviderTurnEvent, ProviderTurnPayload};

fn event() -> ProviderEvent {
    ProviderEvent {
        sequence: 7,
        kind: ProviderEventKind::Turn(Box::new(ProviderTurnEvent {
            version: 1,
            metadata: None,
            payload: ProviderTurnPayload::Finished {
                reason: "completed".into(),
                identity: None,
                usage: None,
                tool_calls: Vec::new(),
                responses_output: Some(vec![
                    serde_json::json!({"type":"reasoning","encrypted_content":"retained"}),
                ]),
                anthropic_output: None,
            },
        })),
        text: String::new(),
        tokens: 0,
    }
}

#[test]
fn protobuf_preserves_rich_payload_separately_from_text() {
    let original = event();
    let pb::provider_frame::Payload::Event(encoded) =
        protobuf(std::slice::from_ref(&original)).expect("provider turn encoding fixture")
    else {
        panic!("protobuf event required");
    };
    assert_eq!(encoded.sequence, 7);
    assert_eq!(encoded.kind, "turn.v1");
    assert!(encoded.text.is_empty());
    let decoded =
        ProviderTurnEvent::decode(&encoded.turn_json).expect("provider turn encoding fixture");
    assert_eq!(ProviderEventKind::Turn(Box::new(decoded)), original.kind);
}

#[test]
fn rich_payload_cannot_silently_become_text() {
    let mut original = event();
    #[cfg(not(feature = "arrow"))]
    assert!(arrow(std::slice::from_ref(&original)).is_err());
    original.text = "smuggled legacy text".into();
    assert!(protobuf(std::slice::from_ref(&original)).is_err());
    original.text.clear();
    original.tokens = 1;
    assert!(protobuf(std::slice::from_ref(&original)).is_err());
}

#[cfg(feature = "arrow")]
#[test]
fn arrow_rich_schema_preserves_the_same_terminal_payload() {
    let original = event();
    let pb::provider_frame::Payload::Arrow(batch) =
        arrow(std::slice::from_ref(&original)).expect("provider turn encoding fixture")
    else {
        panic!("Arrow required")
    };
    let mut reader =
        arrow_ipc::reader::StreamReader::try_new(std::io::Cursor::new(batch.ipc), None)
            .expect("provider turn encoding fixture");
    let record = reader
        .next()
        .expect("provider turn encoding fixture")
        .expect("provider turn encoding fixture");
    assert_eq!(record.num_columns(), 5);
    let payloads = record
        .column(4)
        .as_any()
        .downcast_ref::<arrow_array::BinaryArray>()
        .expect("provider turn encoding fixture");
    let decoded =
        ProviderTurnEvent::decode(payloads.value(0)).expect("provider turn encoding fixture");
    assert_eq!(ProviderEventKind::Turn(Box::new(decoded)), original.kind);
    assert!(reader.next().is_none());
}

#[test]
fn positioned_controls_and_text_round_trip_without_becoming_terminal() {
    use weaver_contracts::{
        ProviderTurnBlockKind, ProviderTurnControl, ProviderTurnMetadata, ProviderTurnPosition,
    };
    for metadata in [
        ProviderTurnMetadata {
            identity: Some(weaver_contracts::ProviderTurnIdentity {
                id: "response-1".into(),
                model: "fixture".into(),
            }),
            usage: None,
            position: None,
            control: Some(ProviderTurnControl::Started),
        },
        ProviderTurnMetadata {
            identity: None,
            usage: None,
            position: Some(ProviderTurnPosition::Responses {
                item_id: "message-1".into(),
                output_index: 0,
                content_index: 1,
            }),
            control: None,
        },
        ProviderTurnMetadata {
            identity: None,
            usage: None,
            position: Some(ProviderTurnPosition::Anthropic { index: 0 }),
            control: Some(ProviderTurnControl::AnthropicStop {
                index: 0,
                block_kind: ProviderTurnBlockKind::Thinking,
                signature: Some("signed".into()),
            }),
        },
    ] {
        let mut original = event();
        let payload = if metadata.control.is_none() {
            ProviderTurnPayload::Text {
                text: "same-text".into(),
            }
        } else {
            ProviderTurnPayload::Control
        };
        let turn = weaver_contracts::ProviderTurnEvent {
            version: 1,
            metadata: Some(metadata),
            payload,
        };
        assert!(!turn.is_terminal());
        original.kind = ProviderEventKind::Turn(Box::new(turn));
        let pb::provider_frame::Payload::Event(encoded) =
            protobuf(std::slice::from_ref(&original)).expect("provider turn encoding fixture")
        else {
            panic!("event")
        };
        assert_eq!(
            ProviderEventKind::Turn(Box::new(
                ProviderTurnEvent::decode(&encoded.turn_json)
                    .expect("provider turn encoding fixture")
            )),
            original.kind
        );
        #[cfg(feature = "arrow")]
        {
            let pb::provider_frame::Payload::Arrow(batch) =
                arrow(std::slice::from_ref(&original)).expect("provider turn encoding fixture")
            else {
                panic!("arrow")
            };
            let mut reader =
                arrow_ipc::reader::StreamReader::try_new(std::io::Cursor::new(batch.ipc), None)
                    .expect("provider turn encoding fixture");
            let record = reader
                .next()
                .expect("provider turn encoding fixture")
                .expect("provider turn encoding fixture");
            let payloads = record
                .column(4)
                .as_any()
                .downcast_ref::<arrow_array::BinaryArray>()
                .expect("provider turn encoding fixture");
            assert_eq!(
                ProviderEventKind::Turn(Box::new(
                    ProviderTurnEvent::decode(payloads.value(0))
                        .expect("provider turn encoding fixture")
                )),
                original.kind
            );
        }
    }
}
