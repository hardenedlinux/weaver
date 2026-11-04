// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Final execution API; writable transports remain private behind deciding guards.
mod broker;
mod provider;
mod transport;
pub use broker::execute::execute;
pub use broker::stream_session::StreamSession;
pub use provider::{
    AnthropicWifConfig, ProviderExecution, ProviderExecutionAuthority, ProviderOutput,
    ProviderTransport, execute_catalog_provider, execute_catalog_provider_with_oauth,
    execute_provider,
};
pub use transport::https::{HttpsTransport, SendObservation};
pub use transport::stream_sink::StreamTlsConfig;
pub use weaver_ledger::StreamClaim as OpenStream;
#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
