//! Authenticated local owner service; the execution crate owns all outbound message bytes.
mod admission;
mod config;
mod connections;
pub mod encoding;
mod grpc;
mod grpc_config;
mod grpc_output;
pub mod pb;
mod rpc_security;
mod runtime;
mod shutdown;
mod source_owner;
pub use config::ServerConfig;
pub use grpc::serve_grpc;
pub use grpc_config::run_from_env;
pub use rpc_security::{GrpcConfig, GrpcListeners, RpcSecurity};
#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
