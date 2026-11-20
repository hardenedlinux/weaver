// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Actual HTTP/TLS/provider path with a labeled advisory test double.
#[path = "http_fixture.rs"]
mod fixture;
use super::{Gateway, Ingress};
use crate::{
    GrpcConfig, RpcSecurity, ServerConfig, admission::Admission, runtime::RuntimeOwner,
    source_owner::SourceOwner,
};
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Duration};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn http_uses_current_source_catalog_exact_turns_and_one_native_delivery_owner() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let directory = tempfile::tempdir().expect("store");
    let database = directory.path().join("http.db");
    let runtime = RuntimeOwner::new();
    runtime.install_fact_feed(fixture::feed()).expect("feed");
    let worker = SourceOwner::start(runtime.clone(), fixture::slot(), database.clone())
        .await
        .expect("source worker");
    let (endpoint, root, mut requests, provider) = fixture::provider().await;
    fixture::register(&worker.client, &endpoint).await;
    let semantic = fixture::advisory(&runtime);
    let settings = GrpcConfig {
        owner: ServerConfig {
            database: database.clone(),
            principal: "alice".into(),
            token_sha256: Sha256::digest(b"operation-token").into(),
            max_in_flight: 4,
        },
        review_authority: weaver_contracts::ReviewAuthority {
            audience: "test-gateway".into(),
            epoch: 0,
            public_key: "4".repeat(64),
            allow_expansion: false,
            qualified_catalog: None,
        },
        security: RpcSecurity {
            tls: tonic::transport::ServerTlsConfig::new(),
            peer_sha256: [2; 32],
            source_peer_sha256: [3; 32],
            admin_sha256: Sha256::digest(b"source-token").into(),
        },
        metering: None,
        provider_oauth: None,
        provider: weaver_broker::ProviderTransport::new(
            [("primary".into(), "provider-secret".into())].into(),
            Some(root.as_bytes()),
            tokio::runtime::Handle::current(),
        )
        .expect("transport"),
    };
    let gateway = Gateway::new(
        &settings,
        Ingress::Operation,
        Admission::new(4),
        runtime.clone(),
        worker.client.operation_resolver(),
    );
    let profile = crate::HttpProfile {
        session: "session-a".into(),
        token_sha256: Sha256::digest(b"http-client-secret").into(),
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("listen");
    let base = format!("http://{}", listener.local_addr().expect("address"));
    let serving = tokio::spawn(crate::http_compat::serve(listener, gateway, profile));
    let client = Arc::new(
        reqwest::Client::builder()
            .no_proxy()
            .http1_only()
            .timeout(Duration::from_secs(5))
            .build()
            .expect("client"),
    );
    let mut parallel = tokio::task::JoinSet::new();
    for token in [
        "wrong",
        "operation-token",
        "source-token",
        "provider-secret",
    ] {
        let client = client.clone();
        let url = format!("{base}/v1/models");
        parallel.spawn(async move {
            assert_eq!(
                client
                    .get(url)
                    .bearer_auth(token)
                    .send()
                    .await
                    .expect("HTTP reject")
                    .status(),
                401
            )
        });
    }
    while let Some(result) = parallel.join_next().await {
        result.expect("four concurrent auth controls");
    }
    let catalog = client
        .get(format!("{base}/v1/models"))
        .bearer_auth("http-client-secret")
        .send()
        .await
        .expect("catalog");
    assert_eq!(catalog.status(), 200);
    let version = catalog.headers()["weaver-catalog-version"]
        .to_str()
        .expect("version")
        .to_owned();
    let models: serde_json::Value =
        serde_json::from_slice(&catalog.bytes().await.expect("models body")).expect("models");
    assert_eq!(models["data"][0]["id"], "model-a");
    assert_eq!(
        client
            .get(format!("{base}/v1/models"))
            .bearer_auth("http-client-secret")
            .header("x-api-key", "http-client-secret")
            .send()
            .await
            .expect("ambiguous")
            .status(),
        401
    );
    assert_eq!(
        client
            .post(format!("{base}/v1/messages"))
            .header("x-api-key", "http-client-secret")
            .header("content-type", "application/json")
            .body("{}")
            .send()
            .await
            .expect("protocol mismatch")
            .status(),
        409
    );
    assert_eq!(
        client
            .post(format!("{base}/v1/RegisterProviderSession"))
            .bearer_auth("http-client-secret")
            .send()
            .await
            .expect("no source endpoint")
            .status(),
        404
    );
    for (key, prompt) in [("first", "one"), ("second", "two")] {
        let body=serde_json::json!({"model":"model-a","stream":true,"max_tokens":32,"messages":[{"role":"user","content":prompt}]}).to_string();
        let response = client
            .post(format!("{base}/v1/chat/completions"))
            .bearer_auth("http-client-secret")
            .header("idempotency-key", key)
            .header("content-type", "application/json")
            .body(body.clone())
            .send()
            .await
            .expect("turn");
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()["content-type"], "text/event-stream");
        let wire = response.bytes().await.expect("guarded complete HTTP body");
        let mut decoder = weaver_llm::TurnDecoder::new(weaver_llm::Protocol::OpenAi, 65_536);
        decoder.push_bytes(&wire).expect("decode wire");
        let mut text = String::new();
        let mut terminal = 0;
        while let Some(event) = decoder.next_event().expect("canonical event") {
            match event {
                weaver_llm::TurnEvent::Text(value) => text.push_str(&value),
                weaver_llm::TurnEvent::Finished { .. } => terminal += 1,
                _ => {}
            }
        }
        assert_eq!(text, "hello");
        assert_eq!(terminal, 1);
        assert_eq!(
            requests.recv().await.expect("real upstream request"),
            body,
            "no request normalization after binding"
        );
    }
    provider.await.expect("exactly two provider requests");
    let retry_body=serde_json::json!({"model":"model-a","stream":true,"max_tokens":32,"messages":[{"role":"user","content":"changed"}]}).to_string();
    assert_eq!(
        client
            .post(format!("{base}/v1/chat/completions"))
            .bearer_auth("http-client-secret")
            .header("idempotency-key", "first")
            .header("content-type", "application/json")
            .body(retry_body)
            .send()
            .await
            .expect("changed retry")
            .status(),
        409
    );
    fixture::change(&worker.client, false).await;
    assert_eq!(
        client
            .get(format!("{base}/v1/models"))
            .bearer_auth("http-client-secret")
            .send()
            .await
            .expect("withdrawn")
            .status(),
        409
    );
    fixture::change(&worker.client, true).await;
    let refreshed = client
        .get(format!("{base}/v1/models"))
        .header("x-api-key", "http-client-secret")
        .send()
        .await
        .expect("A-B-A");
    assert_eq!(refreshed.status(), 200);
    assert_ne!(refreshed.headers()["weaver-catalog-version"], version);
    runtime.drain().await;
    serving
        .await
        .expect("HTTP task")
        .expect("HTTP natural exit");
    worker.finish().await.expect("source joined");
    semantic
        .await
        .expect("advisory joined")
        .expect("advisory natural exit");
}
