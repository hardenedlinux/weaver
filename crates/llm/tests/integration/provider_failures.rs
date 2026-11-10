// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{TestResult, messages, upstream};
use std::time::Duration;
use weaver_llm::{Client, Endpoint, Error, Options, Protocol, Request};

#[tokio::test]
async fn http_failures_are_classified_without_exposing_provider_body() -> TestResult {
    let client = Client::new(Duration::from_secs(2), 4096)?;
    let messages = messages();
    let options = Options::default();
    let request = Request {
        model: "fixture",
        messages: &messages,
        options: &options,
    };
    for (status, headers, body) in [
        (429, "Retry-After: 3\r\n", "secret rate limit detail"),
        (503, "", "secret unavailable detail"),
        (
            400,
            "",
            r#"{"error":{"code":"context_length_exceeded","message":"secret context detail"}}"#,
        ),
        (413, "", "secret byte limit detail"),
    ] {
        let (url, observed) = upstream(format!(
            "HTTP/1.1 {status} Error\r\n{headers}Connection: close\r\n\r\n{body}"
        ))
        .await?;
        let error = client
            .complete(&Endpoint::new(Protocol::OpenAi, &url)?, "key", &request)
            .await
            .err()
            .ok_or_else(|| std::io::Error::other("expected failure"))?;
        assert!(!error.to_string().contains("secret"));
        match status {
            429 => assert!(matches!(
                error,
                Error::RateLimited {
                    retry_after_seconds: Some(3)
                }
            )),
            503 => assert!(matches!(
                error,
                Error::UpstreamUnavailable { status: Some(503) }
            )),
            400 => assert!(matches!(error, Error::ContextLength)),
            _ => assert!(matches!(error, Error::Status(413))),
        }
        observed.await??;
    }
    Ok(())
}

#[tokio::test]
async fn in_band_failure_closes_the_stream() -> TestResult {
    let (url, observed) = upstream(concat!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
        "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\",\"message\":\"private\"}}}\n\n",
    )).await?;
    let mut turn = Client::new(Duration::from_secs(2), 4096)?
        .stream_turn(
            &Endpoint::new(Protocol::OpenAiResponses, &url)?,
            "key",
            &Request {
                model: "fixture",
                messages: &messages(),
                options: &Options::default(),
            },
        )
        .await?;
    assert!(matches!(
        turn.next_event().await,
        Err(Error::UpstreamUnavailable { status: None })
    ));
    assert!(turn.next_event().await?.is_none());
    observed.await??;
    Ok(())
}

#[tokio::test]
async fn buffered_refusals_are_typed_and_redacted() -> TestResult {
    let client = Client::new(Duration::from_secs(2), 4096)?;
    let messages = messages();
    let options = Options::default();
    let request = Request {
        model: "fixture",
        messages: &messages,
        options: &options,
    };
    for (protocol, body) in [
        (
            Protocol::OpenAi,
            r#"{"id":"chat","model":"fixture","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":null,"refusal":"private"}}]}"#,
        ),
        (
            Protocol::OpenAiResponses,
            r#"{"id":"resp","model":"fixture","status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"private"}]}]}"#,
        ),
        (
            Protocol::Anthropic,
            r#"{"id":"msg","model":"fixture","role":"assistant","content":[],"stop_reason":"refusal","stop_details":{"explanation":"private"}}"#,
        ),
    ] {
        let (url, observed) = upstream(format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{body}"
        ))
        .await?;
        let error = client
            .complete(&Endpoint::new(protocol, &url)?, "key", &request)
            .await
            .err()
            .ok_or_else(|| std::io::Error::other("expected refusal"))?;
        assert!(matches!(error, Error::Refused));
        assert!(!error.to_string().contains("private"));
        observed.await??;
    }
    Ok(())
}

#[tokio::test]
async fn streaming_refusals_close_before_normal_completion() -> TestResult {
    let client = Client::new(Duration::from_secs(2), 4096)?;
    let messages = messages();
    let options = Options::default();
    let request = Request {
        model: "fixture",
        messages: &messages,
        options: &options,
    };
    for (protocol, body) in [
        (
            Protocol::OpenAi,
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"refusal\":\"private\"}}]}\n\n",
        ),
        (
            Protocol::OpenAiResponses,
            "data: {\"type\":\"response.refusal.delta\",\"delta\":\"private\"}\n\n",
        ),
        (
            Protocol::Anthropic,
            concat!(
                "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\",\"stop_details\":{\"explanation\":\"private\"}}}\n\n",
                "data: {\"type\":\"message_stop\"}\n\n",
            ),
        ),
    ] {
        let (url, observed) = upstream(format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n{body}"
        ))
        .await?;
        let mut turn = client
            .stream_turn(&Endpoint::new(protocol, &url)?, "key", &request)
            .await?;
        assert!(matches!(turn.next_event().await, Err(Error::Refused)));
        assert!(turn.next_event().await?.is_none());
        observed.await??;
    }
    Ok(())
}
