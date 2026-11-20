// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
use crate::{
    Error, Protocol, TokenCategories, TurnDecoder, TurnEncoder, TurnEvent, TurnIdentity,
    TurnMetadata, TurnObservation,
};
use serde_json::{Value, json};

fn wire(frames: &[Value]) -> Vec<u8> {
    frames
        .iter()
        .flat_map(|v| format!("data: {v}\n\n").into_bytes())
        .collect()
}
fn decode(
    protocol: Protocol,
    bytes: &[u8],
    width: usize,
) -> (Vec<TurnObservation>, Option<TokenCategories>) {
    let mut decoder =
        TurnDecoder::new(protocol, 4 * 1024 * 1024).with_expected_model("fixture".into());
    let mut events = Vec::new();
    'feed: for chunk in bytes.chunks(width) {
        decoder
            .push_bytes(chunk)
            .expect("stream projection fixture");
        while let Some(event) = decoder
            .next_observation()
            .expect("stream projection fixture")
        {
            let terminal = matches!(event.event, Some(TurnEvent::Finished { .. }));
            events.push(event);
            if terminal {
                break 'feed;
            }
        }
    }
    decoder.finish().expect("stream projection fixture");
    (events, decoder.terminal_usage())
}
fn messages(first: &str, last: &str, tool_first: bool) -> Vec<Value> {
    let tool = json!({"type":"tool_use","id":"call","name":"read","input":{"path":"private"}});
    let mut blocks = vec![
        json!({"type":"text","text":first}),
        tool,
        json!({"type":"text","text":last}),
    ];
    if tool_first {
        blocks.swap(0, 1);
    }
    let mut frames = vec![
        json!({"type":"message_start","message":{"id":"r","model":"fixture","usage":{"input_tokens":2,"output_tokens":0}}}),
    ];
    for (index, block) in blocks.into_iter().enumerate() {
        let mut header = block.clone();
        let delta = if block["type"] == "text" {
            header["text"] = json!("");
            json!({"type":"text_delta","text":block["text"]})
        } else {
            header["input"] = json!({});
            json!({"type":"input_json_delta","partial_json":block["input"].to_string()})
        };
        frames.push(json!({"type":"content_block_start","index":index,"content_block":header}));
        frames.push(json!({"type":"content_block_delta","index":index,"delta":delta}));
        frames.push(json!({"type":"content_block_stop","index":index}));
    }
    frames.push(json!({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}));
    frames.push(json!({"type":"message_stop"}));
    frames
}
fn responses(first: &str, last: &str, tool_first: bool) -> Vec<Value> {
    let message = |id: &str, text: &str| json!({"id":id,"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":text,"annotations":[]} ]});
    let tool = json!({"id":"f","type":"function_call","call_id":"call","name":"read","arguments":"{\"path\":\"private\"}","status":"completed"});
    let mut items = vec![message("m1", first), tool, message("m2", last)];
    if tool_first {
        items.swap(0, 1);
    } else {
        items.insert(0,json!({"id":"thought","type":"reasoning","summary":[{"type":"summary_text","text":"summary"}],"encrypted_content":"opaque"}));
    }
    let mut frames = vec![
        json!({"type":"response.created","response":{"id":"r","model":"fixture","status":"in_progress"}}),
    ];
    for (index, item) in items.iter().enumerate() {
        let mut header = item.clone();
        if item["type"] == "message" {
            header["content"] = json!([]);
        }
        if item["type"] == "function_call" {
            header["arguments"] = json!("");
        }
        frames
            .push(json!({"type":"response.output_item.added","output_index":index,"item":header}));
        if item["type"] == "message" {
            frames.push(json!({"type":"response.content_part.added","output_index":index,"item_id":item["id"],"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}));
            frames.push(json!({"type":"response.output_text.delta","output_index":index,"item_id":item["id"],"content_index":0,"delta":item["content"][0]["text"]}));
        }
    }
    frames.push(json!({"type":"response.completed","response":{"id":"r","model":"fixture","status":"completed","output":items,"usage":{"input_tokens":2,"output_tokens":3,"total_tokens":5}}}));
    frames
}
fn events(bytes: &[u8]) -> Vec<Value> {
    std::str::from_utf8(bytes)
        .expect("stream projection fixture")
        .lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .filter(|s| *s != "[DONE]")
        .map(|s| serde_json::from_str(s).expect("stream projection fixture"))
        .collect()
}
fn project(protocol: Protocol, frames: &[Value], width: usize) -> (Vec<u8>, Vec<u8>) {
    let (source, categories) = decode(protocol, &wire(frames), width);
    let mut encoder =
        TurnEncoder::new(protocol, 4 * 1024 * 1024, 123).expect("stream projection fixture");
    let mut output = Vec::new();
    let mut prefix = Vec::new();
    for event in &source {
        let terminal = matches!(event.event, Some(TurnEvent::Finished { .. }));
        let encoded = encoder
            .push(event, if terminal { categories } else { None })
            .expect("stream projection fixture");
        if !terminal {
            prefix.extend_from_slice(&encoded);
        }
        output.extend_from_slice(&encoded);
    }
    let (round_trip, reported) = decode(protocol, &output, width);
    assert_eq!(
        round_trip.last().expect("stream projection fixture").event,
        source.last().expect("stream projection fixture").event
    );
    assert_eq!(reported, categories);
    assert!(
        encoder
            .push(
                source.last().expect("stream projection fixture"),
                categories
            )
            .is_err()
    );
    (output, prefix)
}
proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config {cases:64,rng_seed:proptest::test_runner::RngSeed::Fixed(293),..Default::default()})]
    #[test]
    fn ordered_projection_preserves_content_without_replaying_prefix(
        first in "[a-z]{1,12}",last in "[A-Z]{1,12}",tool_first in proptest::bool::ANY,width in 1usize..96
    ) {
        for (protocol,frames) in [(Protocol::Anthropic,messages(&first,&last,tool_first)),(Protocol::OpenAiResponses,responses(&first,&last,tool_first))] {
            let (output,prefix)=project(protocol,&frames,width);
            let early=String::from_utf8(prefix).expect("stream projection fixture");
            proptest::prop_assert!(!early.contains("private") && !early.contains("\"name\""));
            let data=events(&output);
            let text:String=data.iter().filter_map(|v| {
                if v["type"]=="response.output_text.delta" {v["delta"].as_str()}
                else if v["delta"]["type"]=="text_delta" {v["delta"]["text"].as_str()} else {None}
            }).collect();
            proptest::prop_assert_eq!(text,format!("{first}{last}"));
            let starts:Vec<_>=data.iter().filter(|v|v["type"]=="content_block_start" || v["type"]=="response.output_item.added").map(|v|v["index"].as_u64().or_else(||v["output_index"].as_u64()).expect("stream projection fixture")).collect();
            proptest::prop_assert!(starts.iter().enumerate().all(|(i,n)|i as u64==*n));
            if protocol==Protocol::OpenAiResponses {proptest::prop_assert!(data.iter().enumerate().all(|(i,v)|v["sequence_number"]==i));}
            if tool_first {proptest::prop_assert!(!early.contains("text_delta") && !early.contains("output_text.delta"));}
            else {proptest::prop_assert!(early.contains(&first));}
        }
    }
}

#[test]
fn abort_budget_and_identity_changes_close_projection_without_tool_completion() {
    let (source, categories) = decode(
        Protocol::Anthropic,
        &wire(&messages("first", "tail", false)),
        3,
    );
    let mut encoder = TurnEncoder::new(Protocol::Anthropic, 4 * 1024 * 1024, 123)
        .expect("stream projection fixture");
    encoder
        .push(&source[0], None)
        .expect("stream projection fixture");
    encoder.abort();
    assert!(
        encoder
            .push(
                source.last().expect("stream projection fixture"),
                categories
            )
            .is_err()
    );
    let mut bounded =
        TurnEncoder::new(Protocol::Anthropic, 16, 123).expect("stream projection fixture");
    assert!(matches!(bounded.push(&source[0], None), Err(Error::Limit)));
    assert!(
        bounded
            .push(
                source.last().expect("stream projection fixture"),
                categories
            )
            .is_err()
    );
    let mut encoder = TurnEncoder::new(Protocol::Anthropic, 4 * 1024 * 1024, 123)
        .expect("stream projection fixture");
    encoder
        .push(&source[0], None)
        .expect("stream projection fixture");
    let changed = TurnObservation {
        event: None,
        metadata: Some(TurnMetadata {
            identity: Some(TurnIdentity {
                id: "foreign".into(),
                model: "fixture".into(),
            }),
            usage: None,
            position: None,
            control: None,
        }),
    };
    assert!(encoder.push(&changed, None).is_err());
    assert!(
        encoder
            .push(
                source.last().expect("stream projection fixture"),
                categories
            )
            .is_err()
    );
}

#[test]
fn chat_tools_wait_for_terminal_while_text_streams_and_usage_stays_reported() {
    let mut bytes = wire(&[
        json!({"id":"r","model":"fixture","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}),
        json!({"id":"r","model":"fixture","choices":[{"index":0,"delta":{"content":"prefix"},"finish_reason":null}]}),
        json!({"id":"r","model":"fixture","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call","type":"function","function":{"name":"read","arguments":"{\"path\":\"private\"}"}}]},"finish_reason":null}]}),
        json!({"id":"r","model":"fixture","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}),
    ]);
    bytes.extend_from_slice(b"data: [DONE]\n\n");
    let (source, categories) = decode(Protocol::OpenAi, &bytes, 3);
    let mut encoder =
        TurnEncoder::new(Protocol::OpenAi, 16384, 123).expect("stream projection fixture");
    let mut out = Vec::new();
    for event in &source {
        let terminal = matches!(event.event, Some(TurnEvent::Finished { .. }));
        let bytes = encoder
            .push(event, if terminal { categories } else { None })
            .expect("stream projection fixture");
        if !terminal {
            assert!(
                !std::str::from_utf8(&bytes)
                    .expect("stream projection fixture")
                    .contains("private")
            );
        }
        out.extend_from_slice(&bytes);
    }
    assert_eq!(
        decode(Protocol::OpenAi, &out, 2)
            .0
            .last()
            .expect("stream projection fixture")
            .event,
        source.last().expect("stream projection fixture").event
    );
}

#[test]
fn interleaved_earlier_response_text_remains_live_after_tool_barrier() {
    let mut frames = responses("prefix", "tail", false);
    let at = frames
        .iter()
        .position(|v| v["type"] == "response.output_text.delta")
        .expect("stream projection fixture");
    frames[at]["delta"] = json!("pre");
    let tool = frames
        .iter()
        .position(|v| {
            v["type"] == "response.output_item.added" && v["item"]["type"] == "function_call"
        })
        .expect("stream projection fixture");
    frames.insert(tool+1,json!({"type":"response.output_text.delta","output_index":1,"item_id":"m1","content_index":0,"delta":"fix"}));
    let (output, early) = project(Protocol::OpenAiResponses, &frames, 3);
    let early = events(&early);
    assert!(early.iter().any(|v| v["delta"] == "fix"));
    assert!(!early.iter().any(|v| v["delta"] == "tail"));
    assert_eq!(
        events(&output)
            .iter()
            .filter(|v| v["type"] == "response.output_text.delta")
            .count(),
        3
    );
}

#[test]
fn signed_and_redacted_thinking_preserve_exact_continuation_and_standard_headers() {
    let frames = vec![
        json!({"type":"message_start","message":{"id":"r","model":"fixture","usage":{"input_tokens":2,"output_tokens":0}}}),
        json!({"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}),
        json!({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"thought"}}),
        json!({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed"}}),
        json!({"type":"content_block_stop","index":0}),
        json!({"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque"}}),
        json!({"type":"content_block_stop","index":1}),
        json!({"type":"content_block_start","index":2,"content_block":{"type":"text","text":"answer"}}),
        json!({"type":"content_block_stop","index":2}),
        json!({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}),
        json!({"type":"message_stop"}),
    ];
    let (output, early) = project(Protocol::Anthropic, &frames, 1);
    let first = events(&early)
        .into_iter()
        .find(|v| v["type"] == "content_block_start")
        .expect("stream projection fixture");
    assert_eq!(first["content_block"]["signature"], "");
    assert!(
        !std::str::from_utf8(&early)
            .expect("stream projection fixture")
            .contains("opaque")
    );
    assert!(
        std::str::from_utf8(&output)
            .expect("stream projection fixture")
            .contains("opaque")
    );
}

#[test]
fn withheld_first_tool_produces_no_later_header_before_terminal() {
    let (source, _) = decode(
        Protocol::OpenAiResponses,
        &wire(&responses("first", "last", true)),
        3,
    );
    let mut encoder =
        TurnEncoder::new(Protocol::OpenAiResponses, 65536, 123).expect("stream projection fixture");
    let mut prefix = Vec::new();
    for observation in &source {
        if matches!(observation.event, Some(TurnEvent::Finished { .. })) {
            break;
        }
        prefix.extend_from_slice(
            &encoder
                .push(observation, None)
                .expect("stream projection fixture"),
        );
    }
    let later_headers: Vec<_> = events(&prefix)
        .into_iter()
        .filter(|v| v["type"] == "response.output_item.added")
        .collect();
    assert!(
        later_headers.is_empty(),
        "a later item overtook the withheld first tool: {later_headers:?}"
    );
}

#[test]
fn unicode_and_sse_looking_text_cannot_change_frame_structure() {
    let first = "α\ndata: forged\n";
    let last = "🚀\"}\\";
    for (protocol, frames) in [
        (Protocol::Anthropic, messages(first, last, false)),
        (Protocol::OpenAiResponses, responses(first, last, false)),
    ] {
        let (encoded, _) = project(protocol, &frames, 1);
        assert!(
            !std::str::from_utf8(&encoded)
                .expect("stream projection fixture")
                .lines()
                .any(|line| line == "data: forged")
        );
    }
}

#[test]
fn aggregate_budget_exhaustion_after_prefix_returns_no_partial_terminal_and_cannot_retry() {
    let (source, categories) = decode(
        Protocol::Anthropic,
        &wire(&messages("prefix", &"x".repeat(4096), false)),
        3,
    );
    let mut encoder =
        TurnEncoder::new(Protocol::Anthropic, 2048, 123).expect("stream projection fixture");
    let mut early = Vec::new();
    for observation in &source {
        if matches!(observation.event, Some(TurnEvent::Finished { .. })) {
            break;
        }
        early.extend_from_slice(
            &encoder
                .push(observation, None)
                .expect("stream projection fixture"),
        );
    }
    assert!(
        std::str::from_utf8(&early)
            .expect("stream projection fixture")
            .contains("prefix")
    );
    assert!(
        !std::str::from_utf8(&early)
            .expect("stream projection fixture")
            .contains("tool_use")
    );
    assert!(matches!(
        encoder.push(
            source.last().expect("stream projection fixture"),
            categories
        ),
        Err(Error::Limit)
    ));
    assert!(
        encoder
            .push(
                source.last().expect("stream projection fixture"),
                categories
            )
            .is_err()
    );
}
