// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

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
