// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Endpoint, SCHEMA, fixtures};
use crate::{ProviderExecution, ProviderOutput, ProviderTransport, execute_provider};
use std::{collections::BTreeMap, sync::atomic::Ordering, time::Duration};
use weaver_contracts::{
    CHAT_TURN_SSE, ProviderEvent, ProviderEventKind, ProviderRoute, ProviderState,
    ProviderTurnPayload, Result, body_digest,
};
use weaver_ledger::{Ledger, ProviderDelivery, ProviderDispatch};

fn sse(events: Vec<serde_json::Value>) -> String {
    events
        .into_iter()
        .map(|event| format!("data: {event}\n\n"))
        .collect()
}

fn responses_reply() -> String {
    sse(vec![
        serde_json::json!({"type":"response.created","response":{"id":"r","model":"model-a","status":"in_progress"}}),
        serde_json::json!({"type":"response.output_item.added","output_index":0,"item":{"id":"reason-1","type":"reasoning","summary":[]}}),
        serde_json::json!({"type":"response.output_item.added","output_index":1,"item":{"id":"call-item-1","type":"function_call","call_id":"call-1","name":"read","arguments":"","status":"in_progress"}}),
        serde_json::json!({"type":"response.completed","response":{
            "id":"r", "model":"model-a", "status":"completed", "output":[
                {"id":"reason-1","type":"reasoning","summary":[],"encrypted_content":"opaque"},
                {"id":"call-item-1","type":"function_call","call_id":"call-1","name":"read","arguments":"{}","status":"completed"}],
            "usage":{"input_tokens":10,"output_tokens":3,"total_tokens":13,
                "input_tokens_details":{"cached_tokens":4,"cache_write_tokens":2}}
        }}),
    ])
}

fn messages_reply() -> String {
    sse(vec![
        serde_json::json!({"type":"message_start","message":{"id":"r","model":"model-a","usage":{"input_tokens":10,"cache_read_input_tokens":4,"cache_creation_input_tokens":2,"output_tokens":0}}}),
        serde_json::json!({"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call-1","name":"read","input":{}}}),
        serde_json::json!({"type":"content_block_stop","index":0}),
        serde_json::json!({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":12,"cache_read_input_tokens":5,"cache_creation_input_tokens":3,"output_tokens":3}}),
        serde_json::json!({"type":"message_stop"}),
    ])
}

#[test]
fn responses_and_messages_use_the_same_guarded_native_pipeline() {
    use weaver_contracts::{ANTHROPIC_TURN_SSE, RESPONSES_TURN_SSE};
    let responses = responses_reply();
    let messages = messages_reply();
    for (protocol, path, reply, request) in [
        (
            RESPONSES_TURN_SSE,
            "/v1/responses",
            responses,
            serde_json::json!({"model":"model-a","stream":true,"store":false,"max_output_tokens":32,"input":[{"role":"user","content":"read"}],"tools":[{"type":"function","name":"read","parameters":{"type":"object"}}]}),
        ),
        (
            ANTHROPIC_TURN_SSE,
            "/v1/messages",
            messages,
            serde_json::json!({"model":"model-a","stream":true,"max_tokens":32,"messages":[{"role":"user","content":"read"}],"tools":[{"name":"read","input_schema":{"type":"object"}}]}),
        ),
    ] {
        let endpoint = Endpoint::with_replies(Duration::ZERO, false, Some(vec![reply]));
        let url = endpoint.address.replace("/v1/chat/completions", path);
        let directory = tempfile::tempdir().expect("provider dispatch fixture");
        let mut ledger =
            Ledger::open(directory.path().join("ledger.db")).expect("provider dispatch fixture");
        ledger
            .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
            .expect("provider dispatch fixture");
        let (mut task, mut plan) = fixtures::task_plan(8, &url);
        let profile = task
            .provider_profile
            .as_mut()
            .expect("provider dispatch fixture");
        profile.protocol = protocol.into();
        plan.profile_commitment = profile.digest().expect("provider dispatch fixture");
        plan.body = request.to_string();
        task.body_digests
            .insert(plan.node.clone(), body_digest(&plan.body));
        task.stream_contracts.insert(
            plan.node.clone(),
            plan.digest().expect("provider dispatch fixture"),
        );
        ledger
            .register_task(&task)
            .expect("provider dispatch fixture");
        let transport = ProviderTransport::new(
            BTreeMap::from([("primary".into(), "fixture-secret".into())]),
            Some(endpoint.root.as_bytes()),
            endpoint.runtime.handle().clone(),
        )
        .expect("provider dispatch fixture");
        let mut output = Capture::default();
        execute_provider(
            &mut ledger,
            ProviderExecution {
                plan: &plan,
                transport: &transport,
                format: "protobuf",
                batch_rows: 1,
            },
            &mut output,
        )
        .expect("provider dispatch fixture");
        let ProviderEventKind::Turn(turn) = &output
            .events
            .last()
            .expect("provider dispatch fixture")
            .kind
        else {
            panic!("rich terminal")
        };
        let ProviderTurnPayload::Finished {
            tool_calls,
            responses_output,
            anthropic_output,
            usage,
            ..
        } = &turn.payload
        else {
            panic!("complete tools")
        };
        assert_eq!(tool_calls[0].id, "call-1");
        assert_eq!(responses_output.is_some(), protocol == RESPONSES_TURN_SSE);
        assert_eq!(anthropic_output.is_some(), protocol == ANTHROPIC_TURN_SSE);
        assert_eq!(endpoint.calls.load(Ordering::SeqCst), 1);
        let connection =
            weaver_ledger::persistence::Session::open(directory.path().join("ledger.db"))
                .expect("provider dispatch fixture");
        let recorded: String = weaver_ledger::persistence::one(
            &connection,
            "SELECT tokens FROM provider_terminal_usage WHERE family='f' AND node='infer'",
            (),
            |row| row.get(0),
        )
        .expect("provider dispatch fixture");
        let counts: [u64; 4] = serde_json::from_str(&recorded).expect("provider dispatch fixture");
        let categories = usage
            .as_ref()
            .expect("provider dispatch fixture")
            .categories
            .as_ref()
            .expect("provider dispatch fixture");
        assert_eq!(
            counts,
            [
                categories.ordinary_input,
                categories.cache_read_input,
                categories.cache_write_input,
                categories.output
            ]
        );
        assert_eq!(
            counts,
            if protocol == RESPONSES_TURN_SSE {
                [4, 4, 2, 3]
            } else {
                [12, 5, 3, 3]
            }
        );
        assert_eq!(
            ledger
                .provider_receipt(&plan.family, &plan.node)
                .expect("provider dispatch fixture")
                .expect("provider dispatch fixture")
                .held,
            plan.ceiling
        );
    }
}

#[derive(Default)]
struct Capture {
    events: Vec<ProviderEvent>,
    stop_after_control: bool,
    credit: Option<usize>,
    projection: Option<crate::ProviderSseEncoder>,
    wire: Vec<u8>,
    preparations: usize,
    fail_preparation: Option<usize>,
}
struct CapturedFrame {
    events: Vec<ProviderEvent>,
    wire: Vec<u8>,
}
impl ProviderOutput for Capture {
    type Slot = ();
    type PreparedFrame = CapturedFrame;
    fn stopped(&self) -> bool {
        self.stop_after_control && self.events.iter().any(|e|
            matches!(&e.kind,ProviderEventKind::Turn(t) if matches!(t.payload,ProviderTurnPayload::Control)))
    }
    fn reserve(&mut self) -> Result<()> {
        if self
            .credit
            .is_some_and(|credit| self.events.len() >= credit)
        {
            return Err(weaver_contracts::Error::Conflict(
                "fixture output credit exhausted",
            ));
        }
        Ok(())
    }
    fn prepare(
        &mut self,
        route: &ProviderRoute,
        model: &str,
        events: &[ProviderEvent],
        format: &str,
    ) -> Result<CapturedFrame> {
        self.preparations += 1;
        if self.fail_preparation == Some(self.preparations) {
            return Err(weaver_contracts::Error::Invalid(
                "fixture projection failure",
            ));
        }
        let wire = if let Some(projection) = &mut self.projection {
            assert_eq!(format, "sse");
            projection.prepare(route, model, events)?
        } else {
            Vec::new()
        };
        Ok(CapturedFrame {
            events: events.to_vec(),
            wire,
        })
    }
    fn emit(&mut self, _: (), frame: CapturedFrame, _: ProviderDelivery) -> Result<()> {
        self.events.extend(frame.events);
        self.wire.extend(frame.wire);
        Ok(())
    }
    fn finish_delivery(&mut self, _: &mut Ledger, _: &ProviderDispatch, _: &str) -> Result<()> {
        Ok(())
    }
}

fn wire(tool: bool) -> String {
    let delta = if tool {
        serde_json::json!({"tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"read","arguments":"{\"path\":\"file\"}"}}]})
    } else {
        serde_json::json!({"content":"done"})
    };
    let event = serde_json::json!({"id":if tool {"turn-1"} else {"turn-2"}, "model":"model-a",
        "choices":[{"index":0,"delta":delta,"finish_reason":if tool {"tool_calls"} else {"stop"}}]});
    format!("data: {event}\n\ndata: [DONE]\n\n")
}

#[test]
fn two_source_bound_turns_share_the_original_budget_and_cannot_replay() {
    let endpoint =
        Endpoint::with_replies(Duration::ZERO, false, Some(vec![wire(true), wire(false)]));
    let directory = tempfile::tempdir().expect("provider dispatch fixture");
    let mut ledger =
        Ledger::open(directory.path().join("ledger.db")).expect("provider dispatch fixture");
    ledger
        .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
        .expect("provider dispatch fixture");
    let (mut task, mut first) = fixtures::task_plan(8, &endpoint.address);
    let profile = task
        .provider_profile
        .as_mut()
        .expect("provider dispatch fixture");
    profile.protocol = CHAT_TURN_SSE.into();
    first.profile_commitment = profile.digest().expect("provider dispatch fixture");
    let mut request: serde_json::Value =
        serde_json::from_str(&first.body).expect("provider dispatch fixture");
    request["tools"] = serde_json::json!([{"type":"function","function":{"name":"read","parameters":{"type":"object"}}}]);
    first.body = request.to_string();
    let mut second = first.clone();
    second.node = "next".into();
    let mut next_body = request;
    next_body["messages"] = serde_json::json!([
        {"role":"user","content":"read file"},
        {"role":"assistant","content":null,"tool_calls":[{"id":"call-1","type":"function","function":{"name":"read","arguments":"{\"path\":\"file\"}"}}]},
        {"role":"tool","tool_call_id":"call-1","content":"fixture contents"}]);
    second.body = next_body.to_string();
    let mut third = second.clone();
    third.node = "over-budget".into();
    for plan in [&second, &third] {
        task.nodes.push(plan.node.clone());
        task.node_cost_bounds
            .insert(plan.node.clone(), plan.ceiling);
    }
    for plan in [&first, &second, &third] {
        task.body_digests
            .insert(plan.node.clone(), body_digest(&plan.body));
        task.stream_contracts.insert(
            plan.node.clone(),
            plan.digest().expect("provider dispatch fixture"),
        );
    }
    ledger
        .register_task(&task)
        .expect("provider dispatch fixture");
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "fixture-secret".into())]),
        Some(endpoint.root.as_bytes()),
        endpoint.runtime.handle().clone(),
    )
    .expect("provider dispatch fixture");
    let mut output = Capture::default();
    for plan in [&first, &second] {
        execute_provider(
            &mut ledger,
            ProviderExecution {
                plan,
                transport: &transport,
                format: "protobuf",
                batch_rows: 1,
            },
            &mut output,
        )
        .expect("provider dispatch fixture");
        assert_eq!(
            ledger
                .provider_receipt(&plan.family, &plan.node)
                .expect("provider dispatch fixture")
                .expect("provider dispatch fixture")
                .state,
            ProviderState::Complete
        );
    }
    assert_eq!(endpoint.calls.load(Ordering::SeqCst), 2);
    let terminal = output
        .events
        .iter()
        .find_map(|event| match &event.kind {
            ProviderEventKind::Turn(turn) => match &turn.payload {
                ProviderTurnPayload::Finished { tool_calls, .. } if !tool_calls.is_empty() => {
                    Some(tool_calls)
                }
                _ => None,
            },
            _ => None,
        })
        .expect("provider dispatch fixture");
    assert_eq!(terminal[0].id, "call-1");
    assert!(
        execute_provider(
            &mut ledger,
            ProviderExecution {
                plan: &first,
                transport: &transport,
                format: "protobuf",
                batch_rows: 1
            },
            &mut output
        )
        .is_err()
    );
    assert_eq!(endpoint.calls.load(Ordering::SeqCst), 2);
    assert_eq!(
        ledger
            .provider_receipt(&first.family, &first.node)
            .expect("provider dispatch fixture")
            .expect("provider dispatch fixture")
            .held,
        first.ceiling + second.ceiling
    );
    assert!(
        execute_provider(
            &mut ledger,
            ProviderExecution {
                plan: &third,
                transport: &transport,
                format: "protobuf",
                batch_rows: 1
            },
            &mut output
        )
        .is_err()
    );
    assert_eq!(endpoint.calls.load(Ordering::SeqCst), 2);
}

#[test]
fn control_frames_obey_cancellation_and_exhausted_credit() {
    for cancelled in [false, true] {
        let endpoint = Endpoint::with_replies(Duration::ZERO, false, Some(vec![responses_reply()]));
        let url = endpoint
            .address
            .replace("/v1/chat/completions", "/v1/responses");
        let directory = tempfile::tempdir().expect("provider dispatch fixture");
        let mut ledger =
            Ledger::open(directory.path().join("ledger.db")).expect("provider dispatch fixture");
        ledger
            .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
            .expect("provider dispatch fixture");
        let (mut task, mut plan) = fixtures::task_plan(8, &url);
        let profile = task
            .provider_profile
            .as_mut()
            .expect("provider dispatch fixture");
        profile.protocol = weaver_contracts::RESPONSES_TURN_SSE.into();
        plan.profile_commitment = profile.digest().expect("provider dispatch fixture");
        plan.body=serde_json::json!({"model":"model-a","stream":true,"store":false,"max_output_tokens":32,"input":[{"role":"user","content":"read"}]}).to_string();
        task.body_digests
            .insert(plan.node.clone(), body_digest(&plan.body));
        task.stream_contracts.insert(
            plan.node.clone(),
            plan.digest().expect("provider dispatch fixture"),
        );
        ledger
            .register_task(&task)
            .expect("provider dispatch fixture");
        let transport = ProviderTransport::new(
            BTreeMap::from([("primary".into(), "fixture-secret".into())]),
            Some(endpoint.root.as_bytes()),
            endpoint.runtime.handle().clone(),
        )
        .expect("provider dispatch fixture");
        let mut output = Capture {
            stop_after_control: cancelled,
            credit: if cancelled { None } else { Some(1) },
            ..Default::default()
        };
        assert!(
            execute_provider(
                &mut ledger,
                ProviderExecution {
                    plan: &plan,
                    transport: &transport,
                    format: "protobuf",
                    batch_rows: 1
                },
                &mut output
            )
            .is_err()
        );
        assert_eq!(endpoint.calls.load(Ordering::SeqCst), 1);
        assert_eq!(output.events.len(), 1);
        assert!(
            matches!(&output.events[0].kind,ProviderEventKind::Turn(t) if matches!(t.payload,ProviderTurnPayload::Control) && !t.is_terminal())
        );
        let receipt = ledger
            .provider_receipt(&plan.family, &plan.node)
            .expect("provider dispatch fixture")
            .expect("provider dispatch fixture");
        assert_ne!(receipt.state, ProviderState::Complete);
        assert_eq!(receipt.held, plan.ceiling);
        let connection =
            weaver_ledger::persistence::Session::open(directory.path().join("ledger.db"))
                .expect("provider dispatch fixture");
        let count: i64 = weaver_ledger::persistence::one(
            &connection,
            "SELECT count(*) FROM provider_terminal_usage",
            (),
            |row| row.get(0),
        )
        .expect("provider dispatch fixture");
        assert_eq!(count, 0);
    }
}

fn run_sse(
    output: &mut Capture,
    protocol: &str,
) -> (Result<()>, weaver_contracts::ProviderReceipt, usize, u64) {
    let (reply, path, body) = match protocol {
        weaver_contracts::RESPONSES_TURN_SSE => (
            responses_reply(),
            "/v1/responses",
            serde_json::json!({"model":"model-a","stream":true,"store":false,"max_output_tokens":32,"input":[{"role":"user","content":"read"}]}),
        ),
        weaver_contracts::ANTHROPIC_TURN_SSE => (
            messages_reply(),
            "/v1/messages",
            serde_json::json!({"model":"model-a","stream":true,"max_tokens":32,"messages":[{"role":"user","content":"read"}]}),
        ),
        CHAT_TURN_SSE => (
            wire(true),
            "/v1/chat/completions",
            serde_json::json!({"model":"model-a","stream":true,"max_tokens":32,"messages":[{"role":"user","content":"read"}]}),
        ),
        _ => unreachable!(),
    };
    let endpoint = Endpoint::with_replies(Duration::ZERO, false, Some(vec![reply]));
    let url = endpoint.address.replace("/v1/chat/completions", path);
    let directory = tempfile::tempdir().expect("provider dispatch fixture");
    let mut ledger =
        Ledger::open(directory.path().join("ledger.db")).expect("provider dispatch fixture");
    ledger
        .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
        .expect("provider dispatch fixture");
    let (mut task, mut plan) = fixtures::task_plan(8, &url);
    let profile = task
        .provider_profile
        .as_mut()
        .expect("provider dispatch fixture");
    profile.protocol = protocol.into();
    plan.profile_commitment = profile.digest().expect("provider dispatch fixture");
    plan.body = body.to_string();
    task.body_digests
        .insert(plan.node.clone(), body_digest(&plan.body));
    task.stream_contracts.insert(
        plan.node.clone(),
        plan.digest().expect("provider dispatch fixture"),
    );
    ledger
        .register_task(&task)
        .expect("provider dispatch fixture");
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "fixture-secret".into())]),
        Some(endpoint.root.as_bytes()),
        endpoint.runtime.handle().clone(),
    )
    .expect("provider dispatch fixture");
    let result = execute_provider(
        &mut ledger,
        ProviderExecution {
            plan: &plan,
            transport: &transport,
            format: "sse",
            batch_rows: 1,
        },
        output,
    );
    let receipt = ledger
        .provider_receipt(&plan.family, &plan.node)
        .expect("provider dispatch fixture")
        .expect("provider dispatch fixture");
    let calls = endpoint.calls.load(Ordering::SeqCst);
    (result, receipt, calls, plan.ceiling)
}
fn sse_capture() -> Capture {
    Capture {
        projection: Some(
            crate::ProviderSseEncoder::new(
                weaver_contracts::RESPONSES_TURN_SSE,
                "model-a",
                65536,
                123,
            )
            .expect("provider dispatch fixture"),
        ),
        ..Default::default()
    }
}

#[test]
fn actual_sse_projection_preserves_guarded_terminal_and_hold() {
    let mut output = sse_capture();
    let (result, receipt, calls, ceiling) =
        run_sse(&mut output, weaver_contracts::RESPONSES_TURN_SSE);
    result.expect("provider dispatch fixture");
    assert_eq!(output.preparations, 4);
    assert_eq!(receipt.state, ProviderState::Complete);
    assert_eq!(receipt.held, ceiling);
    assert_eq!(calls, 1);
    let mut decoder = weaver_llm::TurnDecoder::new(weaver_llm::Protocol::OpenAiResponses, 65536)
        .with_expected_model("model-a".into());
    decoder
        .push_bytes(&output.wire)
        .expect("provider dispatch fixture");
    let mut completed = false;
    while let Some(observation) = decoder
        .next_observation()
        .expect("provider dispatch fixture")
    {
        if let Some(weaver_llm::TurnEvent::Finished {
            tool_calls,
            responses_output,
            ..
        }) = observation.event
        {
            assert_eq!(tool_calls[0].id, "call-1");
            assert_eq!(
                serde_json::to_value(responses_output.expect("provider dispatch fixture"))
                    .expect("provider dispatch fixture")[0]["encrypted_content"],
                "opaque"
            );
            completed = true;
        }
    }
    decoder.finish().expect("provider dispatch fixture");
    assert!(completed);
    assert_eq!(
        decoder.terminal_usage().map(|u| [
            u.ordinary_input,
            u.cache_read_input,
            u.cache_write_input,
            u.output
        ]),
        Some([4, 4, 2, 3])
    );
}

#[test]
fn failed_first_sse_preparation_retains_original_hold_without_output() {
    {
        let failure = 1;
        let mut output = sse_capture();
        output.fail_preparation = Some(failure);
        let (result, receipt, calls, ceiling) =
            run_sse(&mut output, weaver_contracts::RESPONSES_TURN_SSE);
        assert!(result.is_err());
        assert_eq!(output.preparations, failure);
        assert!(
            output.events.is_empty(),
            "snapshot prefix escaped failure at preparation {failure}"
        );
        assert!(output.wire.is_empty());
        assert_eq!(receipt.held, ceiling);
        assert_ne!(receipt.state, ProviderState::Complete);
        assert_eq!(calls, 1);
    }
}

#[test]
fn prepared_sse_snapshot_still_obeys_cancel_and_credit() {
    for cancelled in [false, true] {
        let mut output = sse_capture();
        output.stop_after_control = cancelled;
        output.credit = if cancelled { None } else { Some(1) };
        let (result, receipt, calls, ceiling) =
            run_sse(&mut output, weaver_contracts::RESPONSES_TURN_SSE);
        assert!(result.is_err());
        assert!((1..=4).contains(&output.preparations));
        assert_eq!(output.events.len(), 1);
        assert!(
            !std::str::from_utf8(&output.wire)
                .expect("provider dispatch fixture")
                .contains("function_call")
        );
        assert_eq!(receipt.held, ceiling);
        assert_ne!(receipt.state, ProviderState::Complete);
        assert_eq!(calls, 1);
    }
}

#[test]
fn chat_and_messages_also_project_through_the_actual_sse_guarded_pipeline() {
    for (protocol, sdk, categories) in [
        (CHAT_TURN_SSE, weaver_llm::Protocol::OpenAi, None),
        (
            weaver_contracts::ANTHROPIC_TURN_SSE,
            weaver_llm::Protocol::Anthropic,
            Some([12, 5, 3, 3]),
        ),
    ] {
        let mut output = Capture {
            projection: Some(
                crate::ProviderSseEncoder::new(protocol, "model-a", 65536, 123)
                    .expect("provider dispatch fixture"),
            ),
            ..Default::default()
        };
        let (result, receipt, calls, ceiling) = run_sse(&mut output, protocol);
        result.expect("provider dispatch fixture");
        assert_eq!(receipt.state, ProviderState::Complete);
        assert_eq!(receipt.held, ceiling);
        assert_eq!(calls, 1);
        let mut decoder =
            weaver_llm::TurnDecoder::new(sdk, 65536).with_expected_model("model-a".into());
        decoder
            .push_bytes(&output.wire)
            .expect("provider dispatch fixture");
        let mut complete = false;
        while let Some(observation) = decoder
            .next_observation()
            .expect("provider dispatch fixture")
        {
            if let Some(weaver_llm::TurnEvent::Finished {
                tool_calls,
                anthropic_output,
                ..
            }) = observation.event
            {
                assert_eq!(tool_calls[0].id, "call-1");
                assert_eq!(
                    anthropic_output.is_some(),
                    sdk == weaver_llm::Protocol::Anthropic
                );
                complete = true;
            }
        }
        decoder.finish().expect("provider dispatch fixture");
        assert!(complete);
        assert_eq!(
            decoder.terminal_usage().map(|u| [
                u.ordinary_input,
                u.cache_read_input,
                u.cache_write_input,
                u.output
            ]),
            categories
        );
    }
}

#[test]
fn sse_cannot_upgrade_a_legacy_profile_before_provider_io() {
    let endpoint = Endpoint::new();
    let directory = tempfile::tempdir().expect("provider dispatch fixture");
    let mut ledger =
        Ledger::open(directory.path().join("ledger.db")).expect("provider dispatch fixture");
    ledger
        .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
        .expect("provider dispatch fixture");
    let (task, plan) = fixtures::task_plan(8, &endpoint.address);
    ledger
        .register_task(&task)
        .expect("provider dispatch fixture");
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "fixture-secret".into())]),
        Some(endpoint.root.as_bytes()),
        endpoint.runtime.handle().clone(),
    )
    .expect("provider dispatch fixture");
    let mut output = Capture::default();
    assert!(
        execute_provider(
            &mut ledger,
            ProviderExecution {
                plan: &plan,
                transport: &transport,
                format: "sse",
                batch_rows: 1
            },
            &mut output
        )
        .is_err()
    );
    assert_eq!(endpoint.calls.load(Ordering::SeqCst), 0);
    assert!(output.events.is_empty());
}
