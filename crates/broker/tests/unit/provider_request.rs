// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{IoRuntime, PreparedRequest};
use crate::provider::test_runtime as fixture_runtime;
use std::sync::Arc;
#[test]
fn prepared_bearer_retains_sensitive_debug_redaction_without_io() {
    let runtime = fixture_runtime::fixture_runtime();
    let config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("protocols")
    .with_root_certificates(rustls::RootCertStore::empty())
    .with_no_client_auth();
    let prepared = PreparedRequest::new(
        "https://example.invalid/v1/chat/completions",
        "private-fixture-bearer",
        weaver_contracts::ProviderProtocol::OpenAi,
        None,
        "{}",
        Arc::new(config),
        Arc::new(IoRuntime {
            handle: runtime.handle().clone(),
        }),
    )
    .expect("inert request");
    let authorization = prepared
        .request
        .headers()
        .get("authorization")
        .expect("authorization");
    assert!(authorization.is_sensitive());
    assert_eq!(authorization.as_bytes(), b"Bearer private-fixture-bearer");
    assert!(!format!("{:?}", prepared.request.headers()).contains("private-fixture-bearer"));
}

#[test]
fn expired_anthropic_bearer_is_rejected_before_io() {
    let runtime = fixture_runtime::fixture_runtime();
    let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("protocols")
    .with_root_certificates(rustls::RootCertStore::empty())
    .with_no_client_auth();
    let prepared = PreparedRequest::new(
        "https://example.invalid/v1/messages",
        "sk-ant-oat01-synthetic",
        weaver_contracts::ProviderProtocol::Anthropic,
        Some(tokio::time::Instant::now()),
        "{}",
        Arc::new(tls),
        Arc::new(IoRuntime {
            handle: runtime.handle().clone(),
        }),
    )
    .expect("inert Anthropic request");
    assert!(prepared.request.headers()["authorization"].is_sensitive());
    assert!(!prepared.request.headers().contains_key("x-api-key"));
    let phases = std::cell::Cell::default();
    assert!(matches!(
        prepared.write_and_seal(&phases),
        Err(weaver_contracts::Error::Denied)
    ));
    assert!(!phases.get().connect.attempted);
    assert!(!phases.get().tls.attempted);
    assert!(!phases.get().write.attempted);
    assert!(!phases.get().headers.attempted);
}
