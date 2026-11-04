// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Process-owned RPC identity contracts, shared without service/configuration cycles.
use crate::ServerConfig;
use tonic::transport::ServerTlsConfig;
use weaver_execution::ProviderTransport;
/// Explicit mTLS roots, pinned caller certificate and distinct publication credential.
pub struct RpcSecurity {
    pub tls: ServerTlsConfig,
    pub peer_sha256: [u8; 32],
    pub source_peer_sha256: [u8; 32],
    pub admin_sha256: [u8; 32],
}
/// Distinct bound sockets; source publication never shares execution connection capacity.
pub struct GrpcListeners {
    pub operation: tokio::net::TcpListener,
    pub source: tokio::net::TcpListener,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum RpcRole {
    Operation,
    Source,
}
/// Named deployment inputs for the default Rust RPC owner.
pub struct GrpcConfig {
    /// Independent SPEC review producer verification key, owned by deployment.
    pub review_authority: weaver_contracts::ReviewAuthority,
    pub owner: ServerConfig,
    pub security: RpcSecurity,
    pub provider: ProviderTransport,
}
