// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::SseFraming;
use tokio_sse_codec::Frame;

fn tool_turn_wire() -> Vec<u8> {
    let events = [
        serde_json::json!({"id":"turn", "model":"fixture", "choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"read","arguments":"{\"path\":"}}]}}]}),
        serde_json::json!({"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"file\"}"}}]},"finish_reason":"tool_calls"}]}),
    ];
    let mut wire = Vec::new();
    for event in events {
        wire.extend_from_slice(format!("data: {event}\r\n\r\n").as_bytes());
    }
    wire.extend_from_slice(b"data: [DONE]\r\n\r\n");
    wire
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(128))]
    #[test]
    fn transport_independent_tools_survive_fragmentation(chunk_sizes in proptest::collection::vec(1usize..65, 1..32)) {
        use super::{TurnDecoder, TurnEvent};
        let wire = tool_turn_wire();
        let mut codec = TurnDecoder::new(crate::Protocol::OpenAi, wire.len());
        let mut offset = 0;
        let mut events = Vec::new();
        for size in chunk_sizes.iter().cycle() {
            let end = (offset + size).min(wire.len());
            codec.push_bytes(&wire[offset..end]).expect("stream framing fixture");
            while let Some(event) = codec.next_event().expect("stream framing fixture") {
                events.push(event);
            }
            offset = end;
            // CR alone ends an SSE frame. The terminal can therefore precede
            // the LF of its final CRLF when those bytes arrive separately.
            if offset == wire.len() || matches!(events.last(), Some(TurnEvent::Finished { .. })) { break; }
        }
        codec.finish().expect("stream framing fixture");
        proptest::prop_assert_eq!(events.len(), 1);
        let TurnEvent::Finished { tool_calls, .. } = &events[0] else {
            return Err(proptest::test_runner::TestCaseError::fail("missing terminal tools"));
        };
        proptest::prop_assert_eq!(tool_calls.len(), 1);
        proptest::prop_assert_eq!(&tool_calls[0].id, "call-1");
        proptest::prop_assert_eq!(&tool_calls[0].name, "read");
        proptest::prop_assert_eq!(&tool_calls[0].arguments, &serde_json::json!({"path":"file"}));
        proptest::prop_assert!(codec.next_event().expect("stream framing fixture").is_none());
        proptest::prop_assert!(codec.push_bytes(b"more").is_err());
    }
}

#[test]
fn independent_decoder_rejects_every_truncated_tool_turn() {
    let wire = tool_turn_wire();
    for end in 0..wire.len() - 1 {
        let mut codec = super::TurnDecoder::new(crate::Protocol::OpenAi, wire.len());
        codec
            .push_bytes(&wire[..end])
            .expect("stream framing fixture");
        while let Some(event) = codec.next_event().expect("stream framing fixture") {
            assert!(
                !matches!(event, super::TurnEvent::Finished { .. }),
                "prefix {end}"
            );
        }
        assert!(codec.finish().is_err(), "prefix {end}");
        assert!(codec.push_bytes(&wire[end..]).is_err());
    }
}

#[test]
fn independent_decoder_counts_control_bytes_and_closes_on_failure() {
    let mut codec = super::TurnDecoder::new(crate::Protocol::OpenAi, 8);
    codec
        .push_bytes(b": ping\n\n")
        .expect("stream framing fixture");
    assert!(
        codec
            .next_event()
            .expect("stream framing fixture")
            .is_none()
    );
    assert!(matches!(codec.push_bytes(b"x"), Err(crate::Error::Limit)));
    assert!(codec.finish().is_err());
    assert!(
        codec
            .next_event()
            .expect("stream framing fixture")
            .is_none()
    );
    assert!(codec.push_bytes(b"").is_err());

    let mut codec = super::TurnDecoder::new(crate::Protocol::OpenAi, 128);
    codec
        .push_bytes(b"data: invalid-json\n\n")
        .expect("stream framing fixture");
    assert!(codec.next_event().is_err());
    assert!(codec.finish().is_err());
    assert!(codec.push_bytes(b"data: [DONE]\n\n").is_err());
}

#[test]
fn source_selected_model_and_response_identity_cannot_change_mid_turn() {
    for changed in [
        serde_json::json!({"id":"t", "model":"wrong", "choices":[{"index":0,"delta":{"content":"changed"}}]}),
        serde_json::json!({"id":"other", "model":"fixture", "choices":[{"index":0,"delta":{"content":"changed"}}]}),
    ] {
        let mut codec = super::TurnDecoder::new(crate::Protocol::OpenAi, 4096)
            .with_expected_model("fixture".into());
        codec.push_bytes(b"data: {\"id\":\"t\",\"model\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}\n\n").expect("stream framing fixture");
        assert!(
            codec
                .next_event()
                .expect("stream framing fixture")
                .is_none()
        );
        codec
            .push_bytes(format!("data: {changed}\n\n").as_bytes())
            .expect("stream framing fixture");
        assert!(codec.next_event().is_err());
        assert!(codec.finish().is_err());
    }
}

#[test]
fn sse_events_are_invariant_under_chunk_boundaries() -> Result<(), crate::Error> {
    let wire = b": heartbeat\r\nevent: delta\r\ndata: first\r\ndata:second\r\n\r\ndata: last\r\r\n";
    let expected = [b"first\nsecond".as_slice(), b"last".as_slice()];
    for first in 0..=wire.len() {
        for second in first..=wire.len() {
            let mut frame = SseFraming::new(wire.len());
            let mut actual = Vec::new();
            for slice in [&wire[..first], &wire[first..second], &wire[second..]] {
                frame.push(slice);
                while let Some(frame) = frame.next()? {
                    if let Frame::Event(event) = frame {
                        actual.push(event.data.to_vec());
                    }
                }
            }
            assert_eq!(actual, expected, "splits {first} and {second}");
        }
    }
    Ok(())
}

#[test]
fn responses_terminal_must_match_streamed_text() {
    use super::{Decoder, TurnEvent};
    use crate::Protocol;
    use sha2::Digest;
    use std::collections::BTreeMap;

    fn decoder() -> Decoder {
        Decoder {
            protocol: Protocol::OpenAiResponses,
            tools: BTreeMap::new(),
            finish: None,
            identity: None,
            usage: None,
            anthropic_started: false,
            anthropic_block: None,
            anthropic_output: BTreeMap::new(),
            responses_text: sha2::Sha256::new(),
            expected_model: None,
            categories: None,
        }
    }
    fn terminal(output: serde_json::Value) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "type": "response.completed",
            "response": {"id": "response", "model": "gpt-fixture", "status": "completed", "output": output}
        })).expect("stream framing fixture")
    }
    for output in [
        serde_json::json!([]),
        serde_json::json!([{"type": "message", "content": [{"type": "output_text", "text": "different"}]}]),
    ] {
        let mut turn = decoder();
        assert!(matches!(
            turn.accept(
                br#"{"type":"response.output_text.delta","delta":"shown"}"#,
                false
            )
            .map(|o| o.event),
            Ok(Some(TurnEvent::Text(_)))
        ));
        assert!(turn.accept(&terminal(output), false).is_err());
    }
    let mut turn = decoder();
    turn.accept(
        br#"{"type":"response.output_text.delta","delta":"sho"}"#,
        false,
    )
    .expect("stream framing fixture");
    turn.accept(
        br#"{"type":"response.output_text.delta","delta":"wn"}"#,
        false,
    )
    .expect("stream framing fixture");
    let output = serde_json::json!([{"type": "message", "content": [{"type": "output_text", "text": "shown"}]}]);
    assert!(matches!(
        turn.accept(&terminal(output), false).map(|o| o.event),
        Ok(Some(TurnEvent::Finished { .. }))
    ));
}

#[test]
fn oversized_sse_event_reports_the_provider_byte_limit() {
    let wire = b"data: 012345678901234567890123456789\n\n";
    for split in 0..=wire.len() {
        let mut frame = SseFraming::new(16);
        frame.push(&wire[..split]);
        match frame.next() {
            Err(error) => assert!(
                matches!(error, crate::Error::Limit),
                "split {split}: {error:?}"
            ),
            Ok(None) => {
                frame.push(&wire[split..]);
                assert!(
                    matches!(frame.next(), Err(crate::Error::Limit)),
                    "split {split}"
                );
            }
            Ok(Some(_)) => panic!("oversized SSE event admitted at split {split}"),
        }
    }
    let mut valid = SseFraming::new(128);
    valid.push(wire);
    assert!(matches!(valid.next(), Ok(Some(Frame::Event(_)))));

    let mut malformed = SseFraming::new(128);
    malformed.push(b"event: \xff\ndata: x\n\n");
    assert!(matches!(malformed.next(), Err(crate::Error::Response)));
}
