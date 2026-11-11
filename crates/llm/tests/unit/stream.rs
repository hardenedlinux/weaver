// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::SseFraming;
use tokio_sse_codec::Frame;

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
        }
    }
    fn terminal(output: serde_json::Value) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "type": "response.completed",
            "response": {"id": "response", "model": "gpt-fixture", "status": "completed", "output": output}
        })).unwrap()
    }
    for output in [
        serde_json::json!([]),
        serde_json::json!([{"type": "message", "content": [{"type": "output_text", "text": "different"}]}]),
    ] {
        let mut turn = decoder();
        assert!(matches!(
            turn.accept(br#"{"type":"response.output_text.delta","delta":"shown"}"#),
            Ok(Some(TurnEvent::Text(_)))
        ));
        assert!(turn.accept(&terminal(output)).is_err());
    }
    let mut turn = decoder();
    turn.accept(br#"{"type":"response.output_text.delta","delta":"sho"}"#)
        .unwrap();
    turn.accept(br#"{"type":"response.output_text.delta","delta":"wn"}"#)
        .unwrap();
    let output = serde_json::json!([{"type": "message", "content": [{"type": "output_text", "text": "shown"}]}]);
    assert!(matches!(
        turn.accept(&terminal(output)),
        Ok(Some(TurnEvent::Finished { .. }))
    ));
}
