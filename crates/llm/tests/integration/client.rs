// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use serde_json::Value;
use std::{io, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    task::JoinHandle,
};
use weaver_llm::{Client, Endpoint, Error, Message, Options, Protocol, Request, Role};

type TestResult<T = ()> = Result<T, Box<dyn std::error::Error>>;

async fn upstream(
    reply: impl Into<String>,
) -> io::Result<(String, JoinHandle<io::Result<(String, Value)>>)> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("http://{}/model", listener.local_addr()?);
    let reply = reply.into();
    let task = tokio::spawn(async move {
        let (socket, _) = listener.accept().await?;
        let mut socket = BufReader::new(socket);
        let request = read_request(&mut socket).await?;
        socket.get_mut().write_all(reply.as_bytes()).await?;
        Ok(request)
    });
    Ok((url, task))
}

async fn read_request(socket: &mut BufReader<TcpStream>) -> io::Result<(String, Value)> {
    let mut headers = String::new();
    let mut length = None;
    loop {
        let mut line = String::new();
        if socket.read_line(&mut line).await? == 0 {
            return Err(io::Error::other("request headers ended early"));
        }
        if line == "\r\n" {
            break;
        }
        if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            length = value.trim().parse::<usize>().ok();
        }
        headers.push_str(&line);
    }
    let mut request = vec![0; length.ok_or_else(|| io::Error::other("missing content length"))?];
    socket.read_exact(&mut request).await?;
    Ok((
        headers.to_ascii_lowercase(),
        serde_json::from_slice(&request)?,
    ))
}

fn messages() -> [Message; 2] {
    [
        Message {
            role: Role::System,
            content: "Be concise.".into(),
            images: Vec::new(),
            name: None,
            tool_call_id: None,
            tool_calls: Vec::new(),
            responses_output: None,
        },
        Message {
            role: Role::User,
            content: "Hello".into(),
            images: Vec::new(),
            name: None,
            tool_call_id: None,
            tool_calls: Vec::new(),
            responses_output: None,
        },
    ]
}

#[tokio::test]
async fn normalizes_text_completion_for_both_providers() -> TestResult {
    let client = Client::new(Duration::from_secs(2), 4096)?;
    let messages = messages();
    let options = Options {
        max_tokens: Some(20),
        ..Options::default()
    };
    let request = Request {
        model: "model-a",
        messages: &messages,
        options: &options,
    };

    let (url, observed) = upstream(concat!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
        r#"{"id":"one","model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1}}"#,
    )).await?;
    let completion = client
        .complete(&Endpoint::new(Protocol::OpenAi, &url)?, "key", &request)
        .await?;
    let (headers, payload) = observed.await??;
    assert!(headers.contains("authorization: bearer key\r\n"));
    assert_eq!(payload["messages"][0]["role"], "system");
    assert_eq!(payload["stream"], false);
    assert_eq!(completion.choices[0].message.content, "Hi");
    assert_eq!(completion.usage.map(|usage| usage.output_tokens), Some(1));

    let (url, observed) = upstream(concat!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
        r#"{"id":"two","model":"model-a","role":"assistant","content":[{"type":"text","text":"Hi"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1}}"#,
    )).await?;
    let completion = client
        .complete(&Endpoint::new(Protocol::Anthropic, &url)?, "key", &request)
        .await?;
    let (headers, payload) = observed.await??;
    assert!(headers.contains("x-api-key: key\r\n"));
    assert!(headers.contains("anthropic-version: 2023-06-01\r\n"));
    assert_eq!(payload["system"][0]["text"], "Be concise.");
    assert_eq!(payload["messages"][0]["role"], "user");
    assert_eq!(payload["max_tokens"], 20);
    assert_eq!(completion.choices[0].message.content, "Hi");
    assert_eq!(completion.usage.map(|usage| usage.input_tokens), Some(2));
    Ok(())
}

#[tokio::test]
async fn streams_native_bytes_and_enforces_response_limit() -> TestResult {
    let messages = messages();
    let options = Options::default();
    let request = Request {
        model: "model-a",
        messages: &messages,
        options: &options,
    };
    let response = concat!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nConnection: close\r\n\r\n",
        "data: hi\n\ndata: [DONE]\n\n",
    );
    let (url, observed) = upstream(response).await?;
    let endpoint = Endpoint::new(Protocol::OpenAi, &url)?;
    let mut stream = Client::new(Duration::from_secs(2), 64)?
        .stream(&endpoint, "key", &request)
        .await?;
    let mut body = Vec::new();
    while let Some(chunk) = stream.next_chunk().await? {
        body.extend_from_slice(&chunk);
    }
    assert_eq!(body, b"data: hi\n\ndata: [DONE]\n\n");
    assert_eq!(observed.await??.1["stream"], true);

    let (url, observed) = upstream(response).await?;
    let endpoint = Endpoint::new(Protocol::OpenAi, &url)?;
    let mut stream = Client::new(Duration::from_secs(2), 1)?
        .stream(&endpoint, "key", &request)
        .await?;
    assert!(matches!(stream.next_chunk().await, Err(Error::Limit)));
    assert!(stream.next_chunk().await?.is_none());
    observed.await??;
    Ok(())
}

#[tokio::test]
async fn rejects_remote_cleartext_and_reports_redirect_without_following() -> TestResult {
    assert!(Endpoint::new(Protocol::OpenAi, "http://example.invalid/completion").is_err());
    let client = Client::new(Duration::from_secs(2), 4096)?;
    let (url, observed) = upstream("HTTP/1.1 307 Temporary Redirect\r\nLocation: https://example.invalid/other\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await?;
    let messages = messages();
    let options = Options::default();
    let request = Request {
        model: "model-a",
        messages: &messages,
        options: &options,
    };
    assert!(matches!(
        client
            .complete(&Endpoint::new(Protocol::OpenAi, &url)?, "key", &request)
            .await,
        Err(Error::Status(307))
    ));
    observed.await??;
    Ok(())
}

const OPENAI_TOOL_TURN: &str = concat!(
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Checking.\"}}]}\n\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[",
    "{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}},",
    "{\"index\":1,\"id\":\"call-2\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}\n\n",
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"\\\"other\\\"}\"}},",
    "{\"index\":0,\"function\":{\"arguments\":\"\\\"README\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n",
    "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":5}}\n\n",
    "data: [DONE]\n\n",
);

const ANTHROPIC_TOOL_TURN: &str = concat!(
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
    "event: message_start\r\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\r\n\r\n",
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\r\n\r\n",
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Checking.\"}}\r\n\r\n",
    "data: {\"type\":\"content_block_stop\",\"index\":0}\r\n\r\n",
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call-1\",\"name\":\"read_file\",\"input\":{}}}\r\n\r\n",
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\"}}\r\n\r\n",
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"README\\\"}\"}}\r\n\r\n",
    "data: {\"type\":\"content_block_stop\",\"index\":1}\r\n\r\n",
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":5}}\r\n\r\n",
    "data: {\"type\":\"message_stop\"}\r\n\r\n",
);

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn harness_replays_tool_results_to_both_providers() -> TestResult {
    use serde_json::json;
    use weaver_llm::{Tool, TurnEvent};

    let client = Client::new(Duration::from_secs(2), 4096)?;
    for (protocol, reply, final_reply) in [
        (
            Protocol::OpenAi,
            OPENAI_TOOL_TURN,
            concat!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
                "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Done.\"},\"finish_reason\":\"stop\"}]}\n\n",
                "data: [DONE]\n\n",
            ),
        ),
        (
            Protocol::Anthropic,
            ANTHROPIC_TOOL_TURN,
            concat!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
                "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":4,\"output_tokens\":0}}}\n\n",
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"Done.\"}}\n\n",
                "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n",
                "data: {\"type\":\"message_stop\"}\n\n",
            ),
        ),
    ] {
        let (url, observed) = upstream(reply).await?;
        let mut conversation = messages().to_vec();
        let options = Options {
            tools: vec![Tool {
                name: "read_file".into(),
                description: "Read a workspace file".into(),
                parameters: json!({"type":"object","properties":{"path":{"type":"string"}}}),
            }],
            stream_usage: true,
            ..Options::default()
        };
        let mut turn = client
            .stream_turn(
                &Endpoint::new(protocol, &url)?,
                "key",
                &Request {
                    model: "model-a",
                    messages: &conversation,
                    options: &options,
                },
            )
            .await?;
        let initial = observed.await??.1;
        let declaration = match protocol {
            Protocol::OpenAi => {
                assert_eq!(initial["stream_options"]["include_usage"], true);
                &initial["tools"][0]["function"]
            }
            Protocol::Anthropic => &initial["tools"][0],
            Protocol::OpenAiResponses => unreachable!("fixture only supplies Chat and Messages"),
        };
        assert_eq!(declaration["name"], "read_file");
        assert_eq!(
            turn.next_event().await?,
            Some(TurnEvent::Text("Checking.".into()))
        );
        let Some(TurnEvent::Finished {
            reason,
            usage,
            tool_calls,
            ..
        }) = turn.next_event().await?
        else {
            return Err(io::Error::other("missing successful tool turn").into());
        };
        assert_eq!(
            usage.map(|usage| (usage.input_tokens, usage.output_tokens)),
            Some((3, 5))
        );
        assert_eq!(
            tool_calls.first().map(|call| &call.arguments),
            Some(&json!({"path":"README"}))
        );
        assert!(turn.next_event().await?.is_none());

        match protocol {
            Protocol::OpenAi => {
                assert_eq!(reason, "tool_calls");
                assert_eq!(
                    tool_calls.get(1).map(|call| &call.arguments),
                    Some(&json!({"path":"other"}))
                );
            }
            Protocol::Anthropic => {
                assert_eq!(reason, "tool_use");
                assert_eq!(tool_calls.len(), 1);
            }
            Protocol::OpenAiResponses => unreachable!("fixture only supplies Chat and Messages"),
        }

        let results: Vec<_> = tool_calls
            .iter()
            .map(|call| Message {
                role: Role::Tool,
                content: format!("fixture file {}", call.arguments["path"]),
                images: Vec::new(),
                name: None,
                tool_call_id: Some(call.id.clone()),
                tool_calls: Vec::new(),
                responses_output: None,
            })
            .collect();
        conversation.push(Message {
            role: Role::Assistant,
            content: "Checking.".into(),
            images: Vec::new(),
            name: None,
            tool_call_id: None,
            tool_calls,
            responses_output: None,
        });
        conversation.extend(results);

        let (url, observed) = upstream(final_reply).await?;
        let mut turn = client
            .stream_turn(
                &Endpoint::new(protocol, &url)?,
                "key",
                &Request {
                    model: "model-a",
                    messages: &conversation,
                    options: &options,
                },
            )
            .await?;
        assert_eq!(
            turn.next_event().await?,
            Some(TurnEvent::Text("Done.".into()))
        );
        assert!(
            matches!(turn.next_event().await?, Some(TurnEvent::Finished { tool_calls, .. }) if tool_calls.is_empty())
        );
        let payload = observed.await??.1;
        match protocol {
            Protocol::OpenAi => {
                assert_eq!(payload["messages"][2]["tool_calls"][0]["id"], "call-1");
                assert_eq!(payload["messages"][3]["tool_call_id"], "call-1");
                assert_eq!(payload["messages"][4]["tool_call_id"], "call-2");
            }
            Protocol::Anthropic => {
                assert_eq!(payload["messages"][1]["content"][1]["id"], "call-1");
                assert_eq!(
                    payload["messages"][2]["content"][0]["tool_use_id"],
                    "call-1"
                );
            }
            Protocol::OpenAiResponses => unreachable!("fixture only supplies Chat and Messages"),
        }
    }
    Ok(())
}

#[tokio::test]
async fn disconnected_tool_turn_is_never_released() -> TestResult {
    let reply = OPENAI_TOOL_TURN
        .strip_suffix("data: [DONE]\n\n")
        .ok_or_else(|| io::Error::other("fixture terminal"))?;
    let (url, observed) = upstream(reply).await?;
    let mut turn = Client::new(Duration::from_secs(2), 4096)?
        .stream_turn(
            &Endpoint::new(Protocol::OpenAi, &url)?,
            "key",
            &Request {
                model: "model-a",
                messages: &messages(),
                options: &Options::default(),
            },
        )
        .await?;
    assert!(matches!(
        turn.next_event().await?,
        Some(weaver_llm::TurnEvent::Text(_))
    ));
    assert!(matches!(turn.next_event().await, Err(Error::Response)));
    assert!(turn.next_event().await?.is_none());
    observed.await??;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn responses_stream_replays_reasoning_and_tool_results_without_server_state() -> TestResult {
    use serde_json::json;
    use tokio_stream::StreamExt;
    use weaver_llm::{Tool, TurnEvent};

    let (url, captured) = upstream(concat!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Checking.\"}\n\n",
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\"}\n\n",
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"id\":\"resp_1\",\"model\":\"gpt-fixture\",",
        "\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"encrypted_content\":\"opaque-fixture\"},",
        "{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README\\\"}\",\"status\":\"completed\"}],",
        "\"usage\":{\"input_tokens\":10,\"output_tokens\":4}}}\n\n",
    )).await?;
    let client = Client::new(Duration::from_secs(2), 8192)?;
    let endpoint = Endpoint::new(Protocol::OpenAiResponses, &url)?;
    let mut conversation = messages().to_vec();
    let options = Options {
        tools: vec![Tool {
            name: "read_file".into(),
            description: "Read a file".into(),
            parameters: json!({"type": "object"}),
        }],
        ..Options::default()
    };
    let mut turn = std::pin::pin!(
        client
            .stream_turn(
                &endpoint,
                "key",
                &Request {
                    model: "gpt-fixture",
                    messages: &conversation,
                    options: &options,
                }
            )
            .await?
            .into_stream()
    );
    assert_eq!(
        turn.next().await.transpose()?,
        Some(TurnEvent::Text("Checking.".into()))
    );
    let Some(TurnEvent::Finished {
        responses_output,
        tool_calls,
        identity,
        ..
    }) = turn.next().await.transpose()?
    else {
        return Err(io::Error::other("missing completed response").into());
    };
    assert!(turn.next().await.is_none());
    assert_eq!(identity.map(|value| value.id).as_deref(), Some("resp_1"));
    let call = tool_calls
        .first()
        .ok_or_else(|| io::Error::other("missing function call"))?;
    assert_eq!(call.arguments, json!({"path": "README"}));
    let call_id = call.id.clone();
    let (headers, payload) = captured.await??;
    assert!(headers.contains("authorization: bearer key\r\n"));
    assert_eq!(payload["store"], false);
    assert_eq!(payload["include"][0], "reasoning.encrypted_content");
    assert_eq!(payload["tools"][0]["name"], "read_file");
    conversation.extend([
        Message {
            role: Role::Assistant,
            content: "Checking.".into(),
            images: Vec::new(),
            name: None,
            tool_call_id: None,
            tool_calls,
            responses_output,
        },
        Message {
            role: Role::Tool,
            content: "fixture file".into(),
            images: Vec::new(),
            name: None,
            tool_call_id: Some(call_id),
            tool_calls: Vec::new(),
            responses_output: None,
        },
    ]);
    let (url, captured) = upstream(concat!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
        "{\"status\":\"completed\",\"id\":\"resp_2\",\"model\":\"gpt-fixture\",",
        "\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done.\"}]}],\"usage\":null}",
    )).await?;
    let response = client
        .complete(
            &Endpoint::new(Protocol::OpenAiResponses, &url)?,
            "key",
            &Request {
                model: "gpt-fixture",
                messages: &conversation,
                options: &Options::default(),
            },
        )
        .await?;
    assert_eq!(response.choices[0].message.content, "Done.");
    let payload = captured.await??.1;
    assert_eq!(payload["input"][2]["encrypted_content"], "opaque-fixture");
    assert_eq!(payload["input"][3]["call_id"], "call_1");
    assert_eq!(payload["input"][4]["type"], "function_call_output");
    assert_eq!(payload["input"][4]["call_id"], "call_1");
    assert!(payload.get("previous_response_id").is_none());
    Ok(())
}

#[tokio::test]
async fn incomplete_responses_stream_never_delivers_calls() -> TestResult {
    use tokio_stream::StreamExt;

    let (url, observed) = upstream(concat!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"{}\"}}\n\n",
        "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}\n\n",
    )).await?;
    let turn = Client::new(Duration::from_secs(2), 4096)?
        .stream_turn(
            &Endpoint::new(Protocol::OpenAiResponses, &url)?,
            "key",
            &Request {
                model: "gpt-fixture",
                messages: &messages(),
                options: &Options::default(),
            },
        )
        .await?;
    let mut events = std::pin::pin!(turn.into_stream());
    assert!(matches!(events.next().await, Some(Err(Error::Response))));
    assert!(events.next().await.is_none());
    observed.await??;
    Ok(())
}

#[tokio::test]
#[ignore = "requires an authorized OpenAI Responses reasoning model and credential"]
async fn live_openai_responses_replays_reasoning_and_tool_output() -> TestResult {
    use serde_json::json;
    use weaver_llm::{Tool, TurnEvent, TurnStream};

    if std::env::var("WEAVER_LIVE_OPENAI_RESPONSES").as_deref() != Ok("1") {
        return Err(io::Error::other(
            "set WEAVER_LIVE_OPENAI_RESPONSES=1 to authorize two provider requests",
        )
        .into());
    }
    let model = std::env::var("WEAVER_LIVE_OPENAI_MODEL")?;
    let key = std::env::var("OPENAI_API_KEY")?;
    let budget = Duration::from_secs(60);
    let client = Client::new(budget, 1024 * 1024)?;
    let endpoint = Endpoint::new(
        Protocol::OpenAiResponses,
        "https://api.openai.com/v1/responses",
    )?;

    async fn terminal(mut turn: TurnStream) -> TestResult<(String, TurnEvent)> {
        let mut text = String::new();
        while let Some(event) = turn.next_event().await? {
            match event {
                TurnEvent::Text(delta) => text.push_str(&delta),
                terminal @ TurnEvent::Finished { .. } => return Ok((text, terminal)),
            }
        }
        Err(io::Error::other("missing terminal provider event").into())
    }

    tokio::time::timeout(budget, async {
        let mut history = vec![Message {
            role: Role::User,
            content: concat!(
                "Call read_marker exactly once with an empty object before answering. ",
                "After receiving the tool result, reply with its exact text."
            )
            .into(),
            images: Vec::new(),
            name: None,
            tool_call_id: None,
            tool_calls: Vec::new(),
            responses_output: None,
        }];
        let options = Options {
            max_tokens: Some(512),
            tools: vec![Tool {
                name: "read_marker".into(),
                description: "Return the marker to quote".into(),
                parameters: json!({"type":"object"}),
            }],
            ..Options::default()
        };
        let (text, event) = terminal(
            client
                .stream_turn(
                    &endpoint,
                    &key,
                    &Request {
                        model: &model,
                        messages: &history,
                        options: &options,
                    },
                )
                .await?,
        )
        .await?;
        let TurnEvent::Finished {
            tool_calls,
            responses_output,
            ..
        } = event
        else {
            return Err(io::Error::other("missing completed tool turn").into());
        };
        let [call] = tool_calls.as_slice() else {
            return Err(io::Error::other("expected exactly one tool call").into());
        };
        assert_eq!(call.name, "read_marker");
        assert_eq!(call.arguments, json!({}));
        let call_id = call.id.clone();
        let output = serde_json::to_value(&responses_output)?;
        assert!(
            output
                .as_array()
                .is_some_and(|items| items.iter().any(|item| {
                    item["type"] == "reasoning"
                        && item["encrypted_content"]
                            .as_str()
                            .is_some_and(|value| !value.is_empty())
                })),
            "provider returned no encrypted reasoning item"
        );

        let marker = "weaver-live-responses-3d5c";
        history.extend([
            Message {
                role: Role::Assistant,
                content: text,
                images: Vec::new(),
                name: None,
                tool_call_id: None,
                tool_calls,
                responses_output,
            },
            Message {
                role: Role::Tool,
                content: marker.into(),
                images: Vec::new(),
                name: None,
                tool_call_id: Some(call_id),
                tool_calls: Vec::new(),
                responses_output: None,
            },
        ]);
        let (text, event) = terminal(
            client
                .stream_turn(
                    &endpoint,
                    &key,
                    &Request {
                        model: &model,
                        messages: &history,
                        options: &options,
                    },
                )
                .await?,
        )
        .await?;
        assert!(matches!(event, TurnEvent::Finished { tool_calls, .. } if tool_calls.is_empty()));
        assert!(
            text.trim() == marker,
            "second turn did not echo the tool result"
        );
        Ok(())
    })
    .await?
}

#[tokio::test]
async fn buffered_tool_turns_match_streamed_tool_results_across_protocols() -> TestResult {
    use serde_json::json;
    use weaver_llm::{Tool, ToolCall};

    const HEADER: &str =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n";
    let examples = [
        (
            Protocol::OpenAi,
            r#"{"id":"chat","model":"gpt-fixture","choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_marker","arguments":"{}"}}]}}]}"#,
            "tool_calls",
        ),
        (
            Protocol::Anthropic,
            r#"{"id":"msg","model":"claude-fixture","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"call_1","name":"read_marker","input":{}}]}"#,
            "tool_use",
        ),
        (
            Protocol::OpenAiResponses,
            r#"{"id":"resp","model":"gpt-fixture","status":"completed","output":[{"type":"reasoning","id":"rs_1","encrypted_content":"opaque-fixture"},{"type":"function_call","status":"completed","call_id":"call_1","name":"read_marker","arguments":"{}"}]}"#,
            "tool_calls",
        ),
    ];
    let client = Client::new(Duration::from_secs(2), 4096)?;
    let options = Options {
        tools: vec![Tool {
            name: "read_marker".into(),
            description: "Return a marker".into(),
            parameters: json!({"type": "object"}),
        }],
        ..Options::default()
    };
    let history = messages();
    for (protocol, body, reason) in examples {
        let (url, observed) = upstream(format!("{HEADER}{body}")).await?;
        let completion = client
            .complete(
                &Endpoint::new(protocol, &url)?,
                "key",
                &Request {
                    model: "test-model",
                    messages: &history,
                    options: &options,
                },
            )
            .await?;
        let choice = &completion.choices[0];
        assert_eq!(choice.finish_reason.as_deref(), Some(reason));
        assert_eq!(
            choice.message.tool_calls,
            [ToolCall {
                id: "call_1".into(),
                name: "read_marker".into(),
                arguments: json!({}),
            }]
        );
        assert_eq!(
            choice.message.responses_output.is_some(),
            protocol == Protocol::OpenAiResponses
        );
        let request = observed.await??.1;
        assert_eq!(request["stream"], false);
        let tool = &request["tools"][0];
        let name = if protocol == Protocol::OpenAi {
            &tool["function"]["name"]
        } else {
            &tool["name"]
        };
        assert_eq!(name, "read_marker");
    }
    Ok(())
}

#[path = "generation_controls.rs"]
mod generation_controls;

#[path = "backpressure.rs"]
mod backpressure;
#[path = "configuration.rs"]
mod configuration;
mod copilot;
#[path = "embeddings.rs"]
mod embeddings;
#[path = "image_inputs.rs"]
mod image_inputs;
#[path = "oauth_issuer.rs"]
mod oauth_issuer;
#[path = "oauth_lifecycle.rs"]
mod oauth_lifecycle;
#[path = "openai_login.rs"]
mod openai_login;
#[path = "provider_failures.rs"]
mod provider_failures;
