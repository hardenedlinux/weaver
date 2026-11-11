// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Provider owner facade; request dispatch and output custody stay private.
mod anthropic_sse;
mod io_runtime;
mod observation;
mod openai_sse;
mod range_output;
pub use observation::{ProviderTransportPhases, TransportStage};
mod request;
mod response;
mod runtime;
mod sse_buffer;
mod wif;
mod wif_cache;
mod write_seal;
pub use runtime::{
    ProviderExecution, ProviderExecutionAdmission, ProviderExecutionAuthority, ProviderOutput,
    ProviderTransport, execute_catalog_provider, execute_catalog_provider_with_oauth,
    execute_provider, execute_provider_progression,
};
pub use wif::AnthropicWifConfig;

#[cfg(test)]
#[path = "../../tests/unit/runtime.rs"]
mod test_runtime;
