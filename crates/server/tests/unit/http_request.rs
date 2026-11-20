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
    fn credential_realms_do_not_union(bearer in 0usize..4, api in 0usize..4, realm in 0usize..4) {
        let token=["http-client-secret","operation-token","source-token","provider-secret"][realm];
        let expected: [u8;32]=Sha256::digest(b"http-client-secret").into();
        let mut headers=http::HeaderMap::new();
        for _ in 0..bearer {headers.append("authorization",format!("Bearer {token}").parse().expect("header"));}
        for _ in 0..api {headers.append("x-api-key",token.parse().expect("header"));}
        let actual=authenticate(&headers,&expected).is_ok();
        proptest::prop_assert_eq!(actual,realm==0 && bearer+api==1,"only one dedicated credential may authenticate");
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
