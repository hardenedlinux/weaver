// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::Decoder;
use weaver_contracts::{ProviderEventKind, ProviderTurnPayload};
use weaver_llm::Protocol;

fn responses_wire(model: &str) -> Vec<u8> {
    let response = serde_json::json!({"type":"response.completed","response":{
        "id":"response-1", "model":model, "status":"completed",
        "output":[{"id":"reason-1","type":"reasoning","encrypted_content":"opaque"},{"type":"function_call","id":"item-1","call_id":"call-1","name":"read","arguments":"{\"path\":\"file\"}"}],
        "usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12,
          "input_tokens_details":{"cached_tokens":4,"cache_write_tokens":2}}}});
    [
        serde_json::json!({"type":"response.created","response":{"id":"response-1","model":model,"status":"in_progress"}}),
        serde_json::json!({"type":"response.output_item.added","output_index":0,"item":{"id":"reason-1","type":"reasoning"}}),
        serde_json::json!({"type":"response.output_item.added","output_index":1,"item":{"id":"item-1","type":"function_call"}}),
        response,
    ].iter().flat_map(|value|format!("data: {value}\n\n").into_bytes()).collect()
}

#[test]
fn shared_responses_codec_preserves_complete_tools_and_opaque_continuation() {
    let runtime = crate::provider::test_runtime::fixture_runtime(Some(4));
    runtime.block_on(async {
        let wire = responses_wire("model-a");
        let mut decoder = Decoder::new(wire.as_slice(), "model-a", Protocol::OpenAiResponses);
        let mut controls = Vec::new();
        let event = loop {
            let event = decoder.next().await.expect("complete provider stream fixture");
            if matches!(&event.kind, ProviderEventKind::Turn(t) if t.is_terminal()) {
                break event;
            }
            controls.push(event);
        };
        assert_eq!(controls.len(), 3);
        assert!(controls.iter().all(|e|matches!(&e.kind,ProviderEventKind::Turn(t) if matches!(t.payload,ProviderTurnPayload::Control) && t.metadata.is_some())));
        let ProviderEventKind::Turn(turn) = event.kind else {
            panic!("rich event required")
        };
        let ProviderTurnPayload::Finished {
            tool_calls,
            responses_output,
            ..
        } = turn.payload
        else {
            panic!("terminal required")
        };
        assert_eq!(tool_calls[0].id, "call-1");
        assert_eq!(tool_calls[0].arguments, serde_json::json!({"path":"file"}));
        assert_eq!(responses_output.expect("complete provider stream fixture")[0]["encrypted_content"], "opaque");
        assert_eq!(decoder.terminal_tokens(), Some([4, 4, 2, 2]));
        assert!(decoder.next().await.is_err());
    });
}

#[test]
fn shared_codec_rejects_wrong_model_truncation_and_incomplete_tools() {
    let runtime = crate::provider::test_runtime::fixture_runtime(Some(4));
    runtime.block_on(async {
        for wire in [responses_wire("wrong-model"), b"data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".to_vec()] {
            let mut decoder = Decoder::new(wire.as_slice(), "model-a", Protocol::OpenAiResponses);
            while let Ok(event) = decoder.next().await {
                assert!(!matches!(event.kind, ProviderEventKind::Turn(turn) if turn.is_terminal()));
            }
        }
        let wire = b"data: {\"id\":\"t\",\"model\":\"model-a\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n";
        let mut decoder = Decoder::new(wire.as_slice(), "model-a", Protocol::OpenAi);
        while let Ok(event) = decoder.next().await {
            assert!(matches!(&event.kind, ProviderEventKind::Turn(t)
                if !t.is_terminal() && matches!(t.payload, ProviderTurnPayload::Control)));
        }
        assert_eq!(decoder.terminal_tokens(), None);
    });
}

struct Fragmented<'a> {
    bytes: &'a [u8],
    width: usize,
}
impl tokio::io::AsyncRead for Fragmented<'_> {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
        output: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        let count = self.width.min(output.remaining()).min(self.bytes.len());
        output.put_slice(&self.bytes[..count]);
        self.bytes = &self.bytes[count..];
        std::task::Poll::Ready(Ok(()))
    }
}

fn text_wire(first: &str, second: &str, swapped: bool) -> Vec<u8> {
    let frames = [
        serde_json::json!({"type":"response.created","response":{"id":"r","model":"model-a","status":"in_progress"}}),
        serde_json::json!({"type":"response.output_item.added","output_index":0,"item":{"id":"m","type":"message","role":"assistant"}}),
        serde_json::json!({"type":"response.content_part.added","output_index":0,"item_id":"m","content_index":0,"part":{"type":"output_text","text":""}}),
        serde_json::json!({"type":"response.content_part.added","output_index":0,"item_id":"m","content_index":1,"part":{"type":"output_text","text":""}}),
        serde_json::json!({"type":"response.output_text.delta","output_index":0,"item_id":"m","content_index":if swapped {1} else {0},"delta":first}),
        serde_json::json!({"type":"response.output_text.delta","output_index":0,"item_id":"m","content_index":if swapped {0} else {1},"delta":second}),
        serde_json::json!({"type":"response.completed","response":{"id":"r","model":"model-a","status":"completed","output":[{"id":"m","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":first,"annotations":[]},{"type":"output_text","text":second,"annotations":[]}]}]}}),
    ];
    frames
        .iter()
        .flat_map(|v| format!("data: {v}\n\n").into_bytes())
        .collect()
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config {cases:64,rng_seed:proptest::test_runner::RngSeed::Fixed(293),..Default::default()})]
    #[test]
    fn broker_preserves_part_assignment_and_rejects_same_text_rebinding(
        first in "[a-z]{1,16}", second in "[A-Z]{1,16}", width in 1usize..96
    ) {
        let runtime=crate::provider::test_runtime::fixture_runtime(Some(4));
        runtime.block_on(async {
            for swapped in [false,true] {
                let wire=text_wire(&first,&second,swapped);
                let mut decoder=Decoder::new(Fragmented {bytes:&wire,width},"model-a",Protocol::OpenAiResponses);
                let mut text=String::new();
                let mut positions=Vec::new();
                let complete=loop {
                    match decoder.next().await {
                        Ok(event)=> {
                            let ProviderEventKind::Turn(turn)=event.kind else {panic!("rich frame")};
                            if let ProviderTurnPayload::Text {text:delta}=&turn.payload {
                                text.push_str(delta);
                                positions.push(turn.metadata.as_ref().expect("complete provider stream fixture").position.clone());
                            }
                            // Every projected frame independently obeys the bounded contract.
                            assert_eq!(weaver_contracts::ProviderTurnEvent::decode(&turn.encode().expect("complete provider stream fixture")).expect("complete provider stream fixture"),*turn);
                            if turn.is_terminal() {break true;}
                        },
                        Err(_)=>break false,
                    }
                };
                assert_eq!(complete,!swapped);
                assert_eq!(text,format!("{first}{second}"));
                assert_eq!(positions[0],Some(weaver_contracts::ProviderTurnPosition::Responses {item_id:"m".into(),output_index:0,content_index:u64::from(swapped)}));
            }
        });
    }
}

#[test]
fn messages_keep_private_fragments_local_and_release_only_closed_signatures() {
    let frames = [
        serde_json::json!({"type":"message_start","message":{"id":"m","model":"model-a","usage":{"input_tokens":2,"output_tokens":0}}}),
        serde_json::json!({"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}),
        serde_json::json!({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"thought"}}),
        serde_json::json!({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}),
        serde_json::json!({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"ned"}}),
        serde_json::json!({"type":"content_block_stop","index":0}),
        serde_json::json!({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"c","name":"read","input":{}}}),
        serde_json::json!({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}),
        serde_json::json!({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"private\"}"}}),
        serde_json::json!({"type":"content_block_stop","index":1}),
        serde_json::json!({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}),
        serde_json::json!({"type":"message_stop"}),
    ];
    let bytes: Vec<u8> = frames
        .iter()
        .flat_map(|v| format!("data: {v}\n\n").into_bytes())
        .collect();
    let runtime = crate::provider::test_runtime::fixture_runtime(Some(4));
    runtime.block_on(async {
        let mut decoder = Decoder::new(
            Fragmented {
                bytes: &bytes,
                width: 3,
            },
            "model-a",
            Protocol::Anthropic,
        );
        let mut released = 0;
        let mut signatures = 0;
        loop {
            let event = decoder
                .next()
                .await
                .expect("complete provider stream fixture");
            let ProviderEventKind::Turn(turn) = event.kind else {
                panic!("rich frame")
            };
            released += 1;
            if turn.is_terminal() {
                let ProviderTurnPayload::Finished { tool_calls, .. } = &turn.payload else {
                    unreachable!()
                };
                assert_eq!(
                    tool_calls[0].arguments,
                    serde_json::json!({"path":"private"})
                );
                break;
            }
            let wire = String::from_utf8(turn.encode().expect("complete provider stream fixture"))
                .expect("complete provider stream fixture");
            assert!(
                !wire.contains("private")
                    && !wire.contains("partial_json")
                    && !wire.contains("\"name\"")
            );
            assert_eq!(decoder.terminal_tokens(), None);
            if let Some(weaver_contracts::ProviderTurnControl::AnthropicStop {
                signature: Some(signature),
                ..
            }) = turn.metadata.as_ref().and_then(|m| m.control.as_ref())
            {
                signatures += 1;
                assert_eq!(signature, "signed");
            }
        }
        assert_eq!(released, 7);
        assert_eq!(signatures, 1);
        assert_eq!(decoder.terminal_tokens(), Some([2, 0, 0, 3]));
    });
}
