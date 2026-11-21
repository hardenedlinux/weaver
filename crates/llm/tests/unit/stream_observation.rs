// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{
    Protocol, TurnBlockKind, TurnControl, TurnDecoder, TurnEvent, TurnObservation, TurnPosition,
};
use serde_json::{Value, json};

fn response_frames() -> Vec<Value> {
    vec![
        json!({"type":"response.created","response":{"id":"r1","model":"fixture","status":"in_progress"}}),
        json!({"type":"response.output_item.added","output_index":0,"item":{"id":"msg1","type":"message","role":"assistant","content":[]}}),
        json!({"type":"response.content_part.added","output_index":0,"item_id":"msg1","content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}),
        json!({"type":"response.content_part.added","output_index":0,"item_id":"msg1","content_index":1,"part":{"type":"output_text","text":"","annotations":[]}}),
        json!({"type":"response.output_text.delta","output_index":0,"item_id":"msg1","content_index":0,"delta":"first"}),
        json!({"type":"response.output_text.delta","output_index":0,"item_id":"msg1","content_index":1,"delta":"second"}),
        json!({"type":"response.output_item.added","output_index":1,"item":{"id":"fc1","type":"function_call","call_id":"call1","name":"read","arguments":""}}),
        json!({"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc1","delta":"private-fragment"}),
        json!({"type":"response.completed","response":{"id":"r1","model":"fixture","status":"completed","output":[
            {"id":"msg1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"first","annotations":[]},{"type":"output_text","text":"second","annotations":[]}]},
            {"id":"fc1","type":"function_call","call_id":"call1","name":"read","arguments":"{\"path\":\"file\"}","status":"completed"}
        ]}}),
    ]
}
fn wire(frames: &[Value]) -> Vec<u8> {
    frames
        .iter()
        .flat_map(|frame| format!("data: {frame}\n\n").into_bytes())
        .collect()
}
fn decode(
    protocol: Protocol,
    frames: &[Value],
    width: usize,
) -> Result<Vec<TurnObservation>, crate::Error> {
    let wire = wire(frames);
    let mut decoder =
        TurnDecoder::new(protocol, wire.len() + 32).with_expected_model("fixture".into());
    let mut observations = Vec::new();
    'feed: for chunk in wire.chunks(width) {
        decoder.push_bytes(chunk)?;
        while let Some(observation) = decoder.next_observation()? {
            let terminal = matches!(observation.event, Some(TurnEvent::Finished { .. }));
            observations.push(observation);
            if terminal {
                break 'feed;
            }
        }
    }
    decoder.finish()?;
    Ok(observations)
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config {cases:64,rng_seed:proptest::test_runner::RngSeed::Fixed(293),..Default::default()})]
    #[test]
    fn response_coordinates_survive_fragmentation(width in 1usize..96) {
        let frames=response_frames();
        proptest::prop_assert_eq!(decode(Protocol::OpenAiResponses,&frames,width).expect("stream observation fixture"),decode(Protocol::OpenAiResponses,&frames,usize::MAX).expect("stream observation fixture"));
    }
    #[test]
    fn message_array_order_survives_fragmentation(
        width in 1usize..96, bad_index in 2u64..64, reversed in proptest::bool::ANY
    ) {
        let mut frames=anthropic_frames();
        proptest::prop_assert_eq!(decode(Protocol::Anthropic,&frames,width).expect("stream observation fixture"),decode(Protocol::Anthropic,&frames,usize::MAX).expect("stream observation fixture"));
        for frame in &mut frames {
            if let Some(index)=frame.get_mut("index") {
                let original=index.as_u64().expect("stream observation fixture");
                *index=json!(if reversed {1-original} else if original==1 {bad_index} else {original});
            }
        }
        // The same positional requirement holds on both public decoding paths.
        proptest::prop_assert!(decode(Protocol::Anthropic,&frames,width).is_err());
        let bytes=wire(&frames);
        let mut decoder=TurnDecoder::new(Protocol::Anthropic,bytes.len()+32);
        decoder.push_bytes(&bytes).expect("stream observation fixture");
        let error=loop {
            match decoder.next_event() {
                Err(_) => break true,
                Ok(None) => break false,
                Ok(Some(_)) => {},
            }
        };
        proptest::prop_assert!(error);
    }
    #[test]
    fn part_assignment_cannot_change_under_fragmentation(
        first in "[a-z]{1,16}", second in "[A-Z]{1,16}", width in 1usize..96
    ) {
        let mut frames=response_frames();
        frames[4]["delta"]=json!(first);
        frames[5]["delta"]=json!(second);
        frames[8]["response"]["output"][0]["content"][0]["text"]=frames[4]["delta"].clone();
        frames[8]["response"]["output"][0]["content"][1]["text"]=frames[5]["delta"].clone();
        proptest::prop_assert!(decode(Protocol::OpenAiResponses,&frames,width).is_ok());
        frames[4]["content_index"]=json!(1);
        frames[5]["content_index"]=json!(0);
        proptest::prop_assert!(decode(Protocol::OpenAiResponses,&frames,width).is_err());
    }
}

#[test]
fn positions_and_terminal_tools_are_distinct_observations() {
    let observations = decode(Protocol::OpenAiResponses, &response_frames(), 7)
        .expect("stream observation fixture");
    let first = observations
        .first()
        .expect("stream observation fixture")
        .metadata
        .as_ref()
        .expect("stream observation fixture");
    assert!(matches!(first.control, Some(TurnControl::Started)));
    assert_eq!(
        first
            .identity
            .as_ref()
            .expect("stream observation fixture")
            .id,
        "r1"
    );
    let text = observations
        .iter()
        .find(|o| matches!(o.event, Some(TurnEvent::Text(_))))
        .expect("stream observation fixture");
    assert_eq!(
        text.metadata
            .as_ref()
            .expect("stream observation fixture")
            .position,
        Some(TurnPosition::Responses {
            item_id: "msg1".into(),
            output_index: 0,
            content_index: 0
        })
    );
    assert!(
        observations
            .iter()
            .filter(|o| !matches!(o.event, Some(TurnEvent::Finished { .. })))
            .all(|o| !format!("{o:?}").contains("private-fragment"))
    );
    assert!(
        matches!(&observations.last().expect("stream observation fixture").event,Some(TurnEvent::Finished{tool_calls,..}) if tool_calls.len()==1 && tool_calls[0].id=="call1")
    );
}

#[test]
fn same_aggregate_text_cannot_be_reassigned_to_another_content_part() {
    let mut frames = response_frames();
    frames[4]["content_index"] = json!(1);
    frames[5]["content_index"] = json!(0);
    assert!(decode(Protocol::OpenAiResponses, &frames, 17).is_err());
    // The original logical API still validates its aggregate transcript; strict
    // coordinates are selected by the adapter's explicit observation API.
    let mut decoder = TurnDecoder::new(Protocol::OpenAiResponses, 16_384);
    decoder
        .push_bytes(&wire(&frames))
        .expect("stream observation fixture");
    let mut finished = false;
    while let Some(event) = decoder.next_event().expect("stream observation fixture") {
        finished |= matches!(event, TurnEvent::Finished { .. });
    }
    assert!(finished);
}

#[test]
fn foreign_identity_item_part_and_terminal_substitutions_close_the_decoder() {
    for mutation in 0..6 {
        let mut frames = response_frames();
        match mutation {
            0 => frames[4]["item_id"] = json!("foreign"),
            1 => frames[3]["content_index"] = json!(2),
            2 => frames[6]["output_index"] = json!(0),
            3 => frames[8]["response"]["id"] = json!("foreign"),
            4 => frames[8]["response"]["output"][0]["id"] = json!("foreign"),
            _ => frames[4]["output_index"] = json!(64),
        }
        let mut decoder = TurnDecoder::new(Protocol::OpenAiResponses, 16_384)
            .with_expected_model("fixture".into());
        decoder
            .push_bytes(&wire(&frames))
            .expect("stream observation fixture");
        loop {
            match decoder.next_observation() {
                Err(_) => break,
                Ok(Some(o)) => assert!(!matches!(o.event, Some(TurnEvent::Finished { .. }))),
                Ok(None) => panic!("substitution was not rejected"),
            }
        }
        assert!(decoder.push_bytes(b"more").is_err());
    }
}

fn anthropic_frames() -> Vec<Value> {
    vec![
        json!({"type":"message_start","message":{"id":"msg","model":"fixture","usage":{"input_tokens":2,"output_tokens":0}}}),
        json!({"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}),
        json!({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"thought"}}),
        json!({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed"}}),
        json!({"type":"content_block_stop","index":0}),
        json!({"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}),
        json!({"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"answer"}}),
        json!({"type":"content_block_stop","index":1}),
        json!({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}),
        json!({"type":"message_stop"}),
    ]
}

#[test]
fn anthropic_unique_indices_do_not_allow_reordered_blocks() {
    let mut frames = anthropic_frames();
    for frame in &mut frames {
        if let Some(index) = frame.get_mut("index") {
            *index = json!(1 - index.as_u64().expect("stream observation fixture"));
        }
    }
    assert!(decode(Protocol::Anthropic, &frames, 3).is_err());
}

#[test]
fn anthropic_positions_and_complete_signature_preserve_block_order() {
    let frames = anthropic_frames();
    let observations = decode(Protocol::Anthropic, &frames, 3).expect("stream observation fixture");
    assert!(observations.iter().any(|o|matches!(&o.metadata,Some(m) if m.control==Some(TurnControl::AnthropicStop {index:0,kind:TurnBlockKind::Thinking,signature:Some("signed".into())}))));
    let answer = observations
        .iter()
        .find(|o| matches!(&o.event,Some(TurnEvent::Text(t)) if t=="answer"))
        .expect("stream observation fixture");
    assert_eq!(
        answer
            .metadata
            .as_ref()
            .expect("stream observation fixture")
            .position,
        Some(TurnPosition::Anthropic { index: 1 })
    );
    assert!(matches!(
        observations
            .last()
            .expect("stream observation fixture")
            .event,
        Some(TurnEvent::Finished {
            anthropic_output: Some(_),
            ..
        })
    ));
}
