// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Authenticated local owner service; the execution crate owns all outbound message bytes.
#![forbid(unsafe_code)]
mod admission;
mod config;
mod connections;
pub mod encoding;
pub mod entrypoint;
mod governance_deployment;
mod governance_owner;
mod grpc;
mod grpc_config;
mod grpc_contracts;
mod grpc_delivery;
mod grpc_delivery_producer;
mod grpc_hard_fact;
mod grpc_listeners;
mod grpc_output;
mod grpc_provider;
#[cfg(feature = "kubernetes")]
mod kubernetes;
pub mod pb;
#[cfg(all(test, unix))]
#[path = "../tests/unit/provider_commit.rs"]
mod provider_commit_tests;
mod provider_import;
mod provider_oauth;
mod review_wire;
mod rpc_security;
mod runtime;
mod session_workflow;
mod shutdown;
mod single_provider;
mod source_artifact;
mod source_composition;
mod source_file;
mod source_identity;
mod source_owner;
mod source_prepare;
mod telemetry;
#[cfg(test)]
#[path = "../tests/unit/fixtures.rs"]
mod test_fixtures;
pub use config::ServerConfig;
pub use governance_owner::GovernanceWorker;
pub use grpc::serve_grpc;
pub use grpc::serve_grpc_with_runtime;
pub use grpc_config::run_from_env;
pub use rpc_security::{GrpcConfig, GrpcListeners, RpcSecurity};
pub use runtime::RuntimeOwner as ServiceRuntime;
pub use source_identity::certificate_identity as source_certificate_identity;
#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());

#[cfg(test)]
#[path = "../tests/unit/review_rpc.rs"]
mod review_rpc_tests;
