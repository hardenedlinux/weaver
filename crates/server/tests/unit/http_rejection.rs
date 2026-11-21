// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{AUTH_HEADERS_CONFLICT, rejected};
use http_body_util::BodyExt;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn only_the_fixed_header_conflict_is_public_on_the_wire() {
    for (status, code, message) in [
        (
            tonic::Status::unauthenticated(AUTH_HEADERS_CONFLICT),
            401,
            AUTH_HEADERS_CONFLICT,
        ),
        (
            tonic::Status::unauthenticated("credential=private-token"),
            401,
            "Request rejected by Weaver",
        ),
        (
            tonic::Status::permission_denied("internal SQL or policy material"),
            403,
            "Request rejected by Weaver",
        ),
    ] {
        let response = rejected(status);
        assert_eq!(response.status(), code);
        let bytes = response
            .into_body()
            .collect()
            .await
            .expect("error body")
            .to_bytes();
        let value: serde_json::Value = serde_json::from_slice(&bytes).expect("public JSON");
        assert_eq!(value["error"]["message"], message);
    }
}
