// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{authenticate, operation_id, read_body};
use sha2::{Digest, Sha256};
use tonic::{body::Body, codegen::http};

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config {
        cases:64, rng_seed:proptest::test_runner::RngSeed::Fixed(293), ..Default::default()
    })]
    #[test]
    fn credential_realms_do_not_union(bearer in 0usize..4, api in 0usize..4, bearer_realm in 0usize..4, api_realm in 0usize..4) {
        let tokens=["http-client-secret","operation-token","source-token","provider-secret"];
        let expected: [u8;32]=Sha256::digest(b"http-client-secret").into();
        let mut headers=http::HeaderMap::new();
        for _ in 0..bearer {headers.append("authorization",format!("Bearer {}",tokens[bearer_realm]).parse().expect("header"));}
        for _ in 0..api {headers.append("x-api-key",tokens[api_realm].parse().expect("header"));}
        let actual=authenticate(&headers,&expected).is_ok();
        let one_identity=bearer<=1 && api<=1 && bearer+api>0 && (bearer==0 || bearer_realm==0) && (api==0 || api_realm==0);
        proptest::prop_assert_eq!(actual,one_identity,"every present header must name the same dedicated credential");
    }
}
#[test]
fn conflicting_credentials_are_refused_in_both_orders_without_exposing_values() {
    let expected: [u8; 32] = Sha256::digest(b"http-client-secret").into();
    for token in ["operation-token", "source-token", "provider-secret"] {
        for (bearer, api) in [("http-client-secret", token), (token, "http-client-secret")] {
            let mut headers = http::HeaderMap::new();
            headers.insert(
                "authorization",
                format!("Bearer {bearer}").parse().expect("bearer"),
            );
            headers.insert("x-api-key", api.parse().expect("API key"));
            let denied =
                authenticate(&headers, &expected).expect_err("never union credential headers");
            assert_eq!(denied.code(), tonic::Code::Unauthenticated);
            assert!(denied.message().contains("Authorization"));
            assert!(denied.message().contains("x-api-key"));
            assert!(denied.message().contains("same credential"));
            assert!(!denied.message().contains(token));
        }
    }
}
#[test]
fn matching_header_encodings_authenticate_once_but_duplicate_fields_do_not() {
    let expected: [u8; 32] = Sha256::digest(b"http-client-secret").into();
    let mut headers = http::HeaderMap::new();
    headers.insert(
        "authorization",
        "Bearer http-client-secret".parse().expect("bearer"),
    );
    headers.insert("x-api-key", "http-client-secret".parse().expect("API key"));
    authenticate(&headers, &expected).expect("one credential in two standard encodings");
    for name in ["authorization", "x-api-key"] {
        let mut duplicated = headers.clone();
        duplicated.append(name, headers[name].clone());
        assert!(authenticate(&duplicated, &expected).is_err());
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn body_budget_counts_fragmented_wire_and_rejects_trailers() {
    use bytes::Bytes;
    use hyper::body::Frame;
    let wire = "{\"text\":\"你好\"}".as_bytes();
    for split in 0..=wire.len() {
        let chunks = vec![
            Ok::<_, tonic::Status>(Frame::data(Bytes::copy_from_slice(&wire[..split]))),
            Ok(Frame::data(Bytes::copy_from_slice(&wire[split..]))),
        ];
        let body = Body::new(http_body_util::StreamBody::new(tokio_stream::iter(chunks)));
        assert_eq!(
            read_body(body, wire.len() as u64)
                .await
                .expect("bounded fragmented body")
                .as_bytes(),
            wire
        );
        let chunks = vec![
            Ok::<_, tonic::Status>(Frame::data(Bytes::copy_from_slice(&wire[..split]))),
            Ok(Frame::data(Bytes::copy_from_slice(&wire[split..]))),
        ];
        let body = Body::new(http_body_util::StreamBody::new(tokio_stream::iter(chunks)));
        assert_eq!(
            read_body(body, wire.len() as u64 - 1)
                .await
                .expect_err("overflow")
                .code(),
            tonic::Code::ResourceExhausted
        );
    }
    let frames = vec![Ok::<_, tonic::Status>(Frame::<Bytes>::trailers(
        http::HeaderMap::new(),
    ))];
    let body = Body::new(http_body_util::StreamBody::new(tokio_stream::iter(frames)));
    assert!(read_body(body, 4096).await.is_err());
}
#[test]
fn duplicate_retry_keys_are_rejected_and_generated_ids_are_distinct() {
    let mut headers = http::HeaderMap::new();
    assert_ne!(
        operation_id(&headers).expect("first"),
        operation_id(&headers).expect("second")
    );
    headers.append("idempotency-key", "turn-1".parse().expect("header"));
    assert_eq!(operation_id(&headers).expect("retained key"), "turn-1");
    headers.append("idempotency-key", "turn-2".parse().expect("header"));
    assert!(operation_id(&headers).is_err());
}
