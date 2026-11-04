// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Real mTLS RPC registry test. The issuer is a test double, not a SPEC analyzer.
#[path = "../integration/rpc_fixture.rs"]
mod rpc;
use crate::{GrpcConfig, GrpcListeners, RpcSecurity, ServerConfig, pb};
use ring::signature::{Ed25519KeyPair, KeyPair};
use sha2::{Digest, Sha256};
use tonic::transport::{Certificate, Identity, ServerTlsConfig};
use weaver_contracts::{DeltaDisposition, DeltaReview, PublicationKey, PublicationReview};

#[tokio::test(flavor = "multi_thread")]
async fn source_rpc_reads_owned_parent_and_registers_only_authenticated_evidence() {
    let directory = tempfile::tempdir().expect("dir");
    let database = directory.path().join("rpc.db");
    let signer = Ed25519KeyPair::from_seed_unchecked(&[23; 32]).expect("test signer");
    let mut ledger = weaver_ledger::Ledger::open(&database).expect("store");
    ledger
        .install_review_authority(&weaver_contracts::ReviewAuthority {
            audience: "test-gateway".into(),
            epoch: 0,
            public_key: hex::encode(signer.public_key().as_ref()),
            allow_expansion: false,
            qualified_catalog: None,
        })
        .expect("deployment provision");
    drop(ledger);
    let pki = rpc::pki();
    assert_ne!(pki.source.der, pki.next.der);
    let listeners = GrpcListeners {
        operation: tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("op"),
        source: tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("source"),
    };
    let op_addr = listeners.operation.local_addr().expect("address");
    let src_addr = listeners.source.local_addr().expect("address");
    let settings = GrpcConfig {
        metering: None,
        review_authority: weaver_contracts::ReviewAuthority {
            audience: "test-gateway".into(),
            epoch: 0,
            public_key: hex::encode(signer.public_key().as_ref()),
            allow_expansion: false,
            qualified_catalog: None,
        },
        owner: ServerConfig {
            database: database.clone(),
            principal: "alice".into(),
            token_sha256: Sha256::digest(b"operation-token").into(),
            max_in_flight: 16,
        },
        security: RpcSecurity {
            tls: ServerTlsConfig::new()
                .identity(Identity::from_pem(&pki.server.pem, &pki.server.key))
                .client_ca_root(Certificate::from_pem(&pki.ca)),
            peer_sha256: Sha256::digest(&pki.operation.der).into(),
            source_peer_sha256: Sha256::digest(&pki.source.der).into(),
            admin_sha256: Sha256::digest(b"source-token").into(),
        },
        provider: weaver_execution::ProviderTransport::new(
            Default::default(),
            None,
            tokio::runtime::Handle::current(),
        )
        .expect("transport"),
    };
    let (stop, stopped) = tokio::sync::oneshot::channel();
    let serving = tokio::spawn(crate::serve_grpc(listeners, settings, async {
        let _ = stopped.await;
    }));
    let source = rpc::connect(src_addr, &pki.source, &pki.ca).await;
    let operation = rpc::connect(op_addr, &pki.operation, &pki.ca).await;
    let request = pb::PublishRequest {
        operation_id: "original".into(),
        expected_revision: None,
        fence: 1,
        policy: "permit(principal,action,resource);".into(),
        schema: include_str!("../../../../prod/policies/provider/schema.json").into(),
    };
    let denied: Result<pb::PublicationKey, _> = rpc::unary(
        operation,
        "operation-token",
        "/weaver.gateway.v1.Gateway/StageReviewedAuthority",
        request.clone(),
    )
    .await;
    assert!(denied.is_err());
    let key: pb::PublicationKey = rpc::unary(
        source.clone(),
        "source-token",
        "/weaver.gateway.v1.Gateway/StageReviewedAuthority",
        request,
    )
    .await
    .expect("stage");
    let context: pb::PublicationReviewContext = rpc::unary(
        source.clone(),
        "source-token",
        "/weaver.gateway.v1.Gateway/InspectPublicationReview",
        key.clone(),
    )
    .await
    .expect("context");
    assert!(context.parent.is_none());
    let issuer = context.reviewer.expect("issuer");
    let actual = context.source.expect("actual source");
    let mut evidence = DeltaReview {
        review: PublicationReview {
            publication: PublicationKey {
                operation_id: key.operation_id.clone(),
                digest: key.digest.clone(),
            },
            parent: None,
            artifact: "controlled external producer evidence".into(),
        },
        audience: issuer.audience,
        reviewer_epoch: issuer.epoch,
        source_epoch: actual.epoch,
        source_identity_digest: actual.identity_digest,
        disposition: DeltaDisposition::Bootstrap,
        delta: "test issuer; no semantic proof claim".into(),
        signature: String::new(),
    };
    evidence.signature = hex::encode(
        signer
            .sign(&hex::decode(evidence.signing_digest().expect("digest")).expect("hex"))
            .as_ref(),
    );
    let wire = pb::DeltaReview {
        review: Some(pb::PublicationReview {
            publication: Some(key.clone()),
            parent: None,
            artifact: evidence.review.artifact.clone(),
        }),
        audience: evidence.audience.clone(),
        reviewer_epoch: evidence.reviewer_epoch,
        source_epoch: evidence.source_epoch,
        source_identity_digest: evidence.source_identity_digest.clone(),
        disposition: pb::DeltaDisposition::Bootstrap as i32,
        delta: evidence.delta.clone(),
        signature: evidence.signature.clone(),
    };
    let mut forged = wire.clone();
    forged.delta.push(' ');
    let rejected: Result<pb::ReviewRegistrationReceipt, _> = rpc::unary(
        source.clone(),
        "source-token",
        "/weaver.gateway.v1.Gateway/RegisterPublicationReview",
        forged,
    )
    .await;
    assert!(rejected.is_err());
    let registered: pb::ReviewRegistrationReceipt = rpc::unary(
        source.clone(),
        "source-token",
        "/weaver.gateway.v1.Gateway/RegisterPublicationReview",
        wire.clone(),
    )
    .await
    .expect("registered");
    assert_eq!(
        registered.review_digest,
        evidence.review.digest().expect("digest")
    );
    let duplicate: pb::ReviewRegistrationReceipt = rpc::unary(
        source.clone(),
        "source-token",
        "/weaver.gateway.v1.Gateway/RegisterPublicationReview",
        wire,
    )
    .await
    .expect("same registration");
    assert_eq!(registered, duplicate);
    let observed: Result<pb::PublicationReceipt, _> = rpc::unary(
        source,
        "source-token",
        "/weaver.gateway.v1.Gateway/InspectPublication",
        key,
    )
    .await;
    assert_eq!(
        observed.expect_err("registry is not publication").code(),
        tonic::Code::NotFound
    );
    let _ = stop.send(());
    tokio::time::timeout(std::time::Duration::from_secs(5), serving)
        .await
        .expect("natural drain")
        .expect("join")
        .expect("serve");
}
