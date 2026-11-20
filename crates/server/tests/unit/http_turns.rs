// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! End-to-end HTTP continuation; the advisory actor remains a labeled double.
#[path = "http_protocol.rs"]
mod protocol;
use super::{Gateway, Ingress, fixture};
use crate::{admission::Admission, runtime::RuntimeOwner, source_owner::SourceOwner};
use protocol::Case;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use weaver_llm::{ToolCall, TurnEvent};

struct Harness {
    runtime: RuntimeOwner,
    source: SourceOwner,
    source_finish: tokio::task::JoinHandle<weaver_contracts::Result<()>>,
    semantic: tokio::task::JoinHandle<weaver_contracts::Result<()>>,
    server: tokio::task::JoinHandle<weaver_contracts::Result<()>>,
    client: reqwest::Client,
    base: String,
    derivations: Arc<AtomicUsize>,
    _lifetime: crate::runtime::ShutdownGuard,
}

#[path = "http_flow.rs"]
mod flow;
impl Harness {
    async fn start(database: &Path, root: &str, scope: Option<(&str, &str)>) -> Self {
        let runtime = RuntimeOwner::new();
        let lifetime = runtime.shutdown_guard();
        runtime.install_fact_feed(fixture::feed()).expect("feed");
        let worker = SourceOwner::start(runtime.clone(), fixture::slot(), database.into())
            .await
            .expect("source owner");
        if let Some((endpoint, protocol)) = scope {
            fixture::register(&worker.client, endpoint, protocol).await;
        }
        let derivations = Arc::new(AtomicUsize::new(0));
        let semantic = fixture::advisory(&runtime, derivations.clone());
        let settings = fixture::settings(database, root);
        let gateway = Gateway::new(
            &settings,
            Ingress::Operation,
            Admission::new(4),
            runtime.clone(),
            worker.client.operation_resolver(),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("HTTP listen");
        let base = format!("http://{}", listener.local_addr().expect("HTTP address"));
        let profile = crate::HttpProfile {
            session: "session-a".into(),
            token_sha256: Sha256::digest(b"http-client-secret").into(),
        };
        let server = tokio::spawn(crate::http_compat::serve(listener, gateway, profile));
        let client = reqwest::Client::builder()
            .no_proxy()
            .http1_only()
            .timeout(Duration::from_secs(5))
            .build()
            .expect("HTTP client");
        let source = worker.client.clone();
        let source_finish = tokio::spawn(worker.finish());
        Self {
            runtime,
            source,
            source_finish,
            semantic,
            server,
            client,
            base,
            derivations,
            _lifetime: lifetime,
        }
    }
    async fn submit(
        &self,
        case: Case,
        key: &str,
        body: &str,
    ) -> Result<reqwest::Response, reqwest::Error> {
        let request = self
            .client
            .post(format!("{}{}", self.base, case.path()))
            .header("idempotency-key", key)
            .header("content-type", "application/json")
            .body(body.to_owned());
        let request = if matches!(case, Case::Messages) {
            request
                .header("x-api-key", "http-client-secret")
                .header("anthropic-version", "2023-06-01")
        } else {
            request.bearer_auth("http-client-secret")
        };
        request.send().await
    }
    async fn finish(self) {
        self.runtime.drain().await;
        self.server
            .await
            .expect("HTTP owner")
            .expect("HTTP natural drain");
        self.source_finish
            .await
            .expect("source owner")
            .expect("source natural drain");
        self.semantic
            .await
            .expect("advisory owner")
            .expect("advisory natural drain");
    }
}
struct Completed {
    calls: Vec<ToolCall>,
    opaque: Option<Value>,
    text: String,
    thinking: String,
}
async fn completed(response: reqwest::Response, case: Case) -> Completed {
    assert_eq!(response.status(), 200, "{case:?}");
    let bytes = response.bytes().await.expect("whole guarded body");
    let mut decoder = weaver_llm::TurnDecoder::new(case.decoder(), 65_536);
    let mut observed = None;
    let mut text = String::new();
    let mut thinking = String::new();
    // Independent transport partition: split JSON escapes, signatures and UTF-8
    // framing without defining packet or final-output equality as the oracle.
    for chunk in bytes.chunks(3) {
        decoder.push_bytes(chunk).expect("fragmented body");
        while let Some(event) = decoder.next_event().expect("valid provider event") {
            match event {
                TurnEvent::Text(part) => text.push_str(&part),
                TurnEvent::Thinking(part) => thinking.push_str(part.as_str()),
                TurnEvent::Finished {
                    identity,
                    usage,
                    tool_calls,
                    responses_output,
                    anthropic_output,
                    ..
                } => {
                    assert!(observed.is_none(), "whole terminal exactly once");
                    assert_eq!(identity.expect("provider identity").model, "model-a");
                    let usage = usage.expect("known usage");
                    assert_eq!((usage.input_tokens, usage.output_tokens), (2, 3));
                    let opaque = match case {
                        Case::Chat => {
                            assert!(responses_output.is_none() && anthropic_output.is_none());
                            None
                        }
                        Case::Responses => {
                            assert!(anthropic_output.is_none());
                            Some(
                                serde_json::to_value(responses_output.expect("Responses items"))
                                    .expect("opaque items"),
                            )
                        }
                        Case::Messages => {
                            assert!(responses_output.is_none());
                            Some(
                                serde_json::to_value(anthropic_output.expect("Messages blocks"))
                                    .expect("opaque blocks"),
                            )
                        }
                    };
                    observed = Some((tool_calls, opaque));
                }
            }
        }
    }
    decoder.finish().expect("successful EOF");
    let (calls, opaque) = observed.expect("complete result required");
    Completed {
        calls,
        opaque,
        text,
        thinking,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn three_http_protocols_retain_tools_across_owner_restart() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    for case in [Case::Chat, Case::Responses, Case::Messages] {
        let directory = tempfile::tempdir().expect("store");
        let database = directory.path().join("turns.db");
        let mut provider = fixture::provider(vec![case.tool_reply(), case.text_reply()]).await;
        let endpoint = provider
            .endpoint
            .replace("/v1/chat/completions", case.path());
        let first_owner = Harness::start(
            &database,
            &provider.root,
            Some((&endpoint, case.protocol())),
        )
        .await;
        let first_body = case.first_request();
        let first = completed(
            first_owner
                .submit(case, "tool-turn", &first_body)
                .await
                .expect("first HTTP headers"),
            case,
        )
        .await;
        assert_eq!(
            first.calls,
            vec![ToolCall {
                id: "call-1".into(),
                name: "read".into(),
                arguments: json!({"path":"file"})
            }],
            "{case:?}"
        );
        assert!(first.text.is_empty());
        assert_eq!(
            first.thinking,
            if matches!(case, Case::Messages) {
                "plan"
            } else {
                ""
            }
        );
        assert_eq!(
            provider.requests.recv().await.expect("first actual send"),
            first_body
        );
        match case {
            Case::Responses => assert_eq!(
                first.opaque.as_ref().expect("items")[0]["encrypted_content"],
                "opaque-keep"
            ),
            Case::Messages => {
                let blocks = first.opaque.as_ref().expect("blocks");
                assert_eq!(
                    blocks[0],
                    json!({"type":"thinking","thinking":"plan","signature":"sig-keep"})
                );
                assert_eq!(
                    blocks[1],
                    json!({"type":"redacted_thinking","data":"opaque-redacted"})
                );
                assert_eq!(
                    blocks[2],
                    json!({"type":"tool_use","id":"call-1","name":"read","input":{"path":"file"}})
                );
            }
            Case::Chat => {}
        }
        let second_body = case.followup(&first.calls, first.opaque);
        assert_eq!(first_owner.derivations.load(Ordering::SeqCst), 1);
        first_owner.finish().await;
        // Recreate both SQL and advisory owners from durable state. Do not
        // register another scope, reset the budget, or reuse a memory catalog.
        let second_owner = Harness::start(&database, &provider.root, None).await;
        let second = completed(
            second_owner
                .submit(case, "result-turn", &second_body)
                .await
                .expect("second HTTP headers"),
            case,
        )
        .await;
        assert_eq!(second.text, "hello");
        assert!(second.calls.is_empty());
        assert_eq!(
            provider.requests.recv().await.expect("second actual send"),
            second_body
        );
        assert_eq!(second_owner.derivations.load(Ordering::SeqCst), 1);
        if let Ok(retry) = second_owner.submit(case, "tool-turn", &first_body).await {
            assert!(
                retry.bytes().await.is_err(),
                "completed retry cannot forge a replayed tool result"
            );
        }
        assert_eq!(
            second_owner.derivations.load(Ordering::SeqCst),
            1,
            "retained retry cannot rederive"
        );
        if let Ok(exhausted) = second_owner.submit(case, "exhausted", &second_body).await {
            assert!(
                exhausted.bytes().await.is_err(),
                "new turn cannot bypass the shared budget"
            );
        }
        assert_eq!(second_owner.derivations.load(Ordering::SeqCst), 2);
        assert!(
            provider.requests.try_recv().is_err(),
            "no third upstream request"
        );
        fixture::change(&second_owner.source, false).await;
        assert_eq!(
            second_owner
                .submit(case, "withdrawn", &second_body)
                .await
                .expect("withdrawal response")
                .status(),
            409
        );
        second_owner.finish().await;
        provider
            .finish()
            .await
            .expect("no extra upstream connection")
            .expect("whole provider replies transmitted");
        let store = weaver_ledger::persistence::Session::open(&database)
            .expect("reopen persisted native state");
        let turns: i64 = weaver_ledger::persistence::one(
            &store,
            "SELECT COUNT(*) FROM provider_session_turns",
            (),
            |row| row.get(0),
        )
        .expect("turn count");
        let runs: i64 = weaver_ledger::persistence::one(
            &store,
            "SELECT COUNT(*) FROM provider_runs",
            (),
            |row| row.get(0),
        )
        .expect("send count");
        let roots:(i64,i64)=weaver_ledger::persistence::one(&store,"SELECT COUNT(DISTINCT budget_root),COUNT(DISTINCT history_root) FROM execution_origins",(),|row|Ok((row.get(0)?,row.get(1)?))).expect("shared roots");
        assert_eq!(
            (turns, runs, roots),
            (3, 2, (1, 1)),
            "{case:?}: retries and restart must not mint a second budget/history"
        );
        let known: i64 = weaver_ledger::persistence::one(
            &store,
            "SELECT COUNT(*) FROM provider_terminal_usage WHERE tokens='[2,0,0,3]'",
            (),
            |row| row.get(0),
        )
        .expect("reported categories");
        assert_eq!(known, 2, "{case:?}: preserve complete reported usage");
        store.close().expect("native store closed");
    }
}
