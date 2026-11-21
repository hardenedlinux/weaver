// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{
    Client, Endpoint, Error, Message, Options, Protocol, Request, Role, TestResult, messages,
    upstream,
};
use std::time::Duration;
use weaver_llm::TurnEvent;

const REPLY: &str = concat!(
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
    r#"{"id":"id","model":"fixture","role":"assistant","content":[{"type":"thinking","thinking":"private-thought","signature":"private-signature"},{"type":"text","text":"OK"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#,
);
const STREAM: &str = concat!(
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"id\",\"model\":\"fixture\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n",
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n",
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"private-thought\"}}\n\n",
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"private-signature\"}}\n\n",
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"OK\"}}\n\n",
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n",
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n",
    "data: {\"type\":\"message_stop\"}\n\n",
);

#[tokio::test]
async fn buffered_thinking_is_preserved_for_the_next_request() -> TestResult {
    let client = Client::new(Duration::from_secs(2), 8192)?;
    let (url, first) = upstream(REPLY).await?;
    let endpoint = Endpoint::new(Protocol::Anthropic, &url)?;
    let initial = messages();
    let options = Options::default();
    let reply = client
        .complete(
            &endpoint,
            "fixture",
            &Request {
                model: "fixture",
                messages: &initial,
                options: &options,
            },
        )
        .await?;
    first.await??;
    let answer = reply.choices[0].message.clone();
    assert_eq!(answer.content, "OK");
    assert!(!format!("{:?}", answer.anthropic_output).contains("private-thought"));
    verify_replay(&client, &initial, answer, &options).await
}

#[tokio::test]
async fn streamed_thinking_is_preserved_for_the_next_request() -> TestResult {
    let client = Client::new(Duration::from_secs(2), 8192)?;
    let (url, first) = upstream(STREAM).await?;
    let endpoint = Endpoint::new(Protocol::Anthropic, &url)?;
    let initial = messages();
    let options = Options::default();
    let mut stream = client
        .stream_turn(
            &endpoint,
            "fixture",
            &Request {
                model: "fixture",
                messages: &initial,
                options: &options,
            },
        )
        .await?;
    let Some(TurnEvent::Thinking(thinking)) = stream.next_event().await? else {
        return Err("missing streamed thinking".into());
    };
    assert_eq!(thinking.as_str(), "private-thought");
    assert!(!format!("{thinking:?}").contains("private-thought"));
    assert_eq!(
        stream.next_event().await?,
        Some(TurnEvent::Text("OK".into()))
    );
    let Some(TurnEvent::Finished {
        anthropic_output,
        tool_calls,
        ..
    }) = stream.next_event().await?
    else {
        return Err("missing terminal event".into());
    };
    assert!(anthropic_output.is_some());
    first.await??;
    let answer = Message {
        role: Role::Assistant,
        content: "OK".into(),
        images: vec![],
        name: None,
        tool_call_id: None,
        tool_calls,
        responses_output: None,
        anthropic_output,
    };
    verify_replay(&client, &initial, answer, &options).await
}

#[tokio::test]
async fn interrupted_tool_output_is_not_reported_as_replayable() -> TestResult {
    const INTERRUPTED: &str = concat!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"id\",\"model\":\"fixture\"}}\n\n",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"tool\",\"input\":{}}}\n\n",
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\n",
        "data: {\"type\":\"message_stop\"}\n\n",
    );
    let client = Client::new(Duration::from_secs(2), 8192)?;
    let (url, first) = upstream(INTERRUPTED).await?;
    let endpoint = Endpoint::new(Protocol::Anthropic, &url)?;
    let initial = messages();
    let options = Options::default();
    let mut stream = client
        .stream_turn(
            &endpoint,
            "fixture",
            &Request {
                model: "fixture",
                messages: &initial,
                options: &options,
            },
        )
        .await?;
    assert!(matches!(stream.next_event().await, Err(Error::Response)));
    first.await??;
    Ok(())
}

async fn verify_replay(
    client: &Client,
    initial: &[Message],
    answer: Message,
    options: &Options,
) -> TestResult {
    let (url, observed) = upstream(REPLY).await?;
    let endpoint = Endpoint::new(Protocol::Anthropic, &url)?;
    let mut changed = answer.clone();
    changed.content.push('!');
    let invalid = [initial[1].clone(), changed];
    assert!(matches!(
        client
            .complete(
                &endpoint,
                "fixture",
                &Request {
                    model: "fixture",
                    messages: &invalid,
                    options
                }
            )
            .await,
        Err(Error::Request(_))
    ));
    let conversation = [initial[1].clone(), answer, initial[1].clone()];
    client
        .complete(
            &endpoint,
            "fixture",
            &Request {
                model: "fixture",
                messages: &conversation,
                options,
            },
        )
        .await?;
    let (_, body) = observed.await??;
    let blocks = &body["messages"][1]["content"];
    assert_eq!(blocks[0]["thinking"], "private-thought");
    assert_eq!(blocks[0]["signature"], "private-signature");
    assert_eq!(blocks[1]["text"], "OK");
    Ok(())
}
