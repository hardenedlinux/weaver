// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Provider owner facade; request dispatch and output custody stay private.
mod io_runtime;
mod request;
mod response;
mod runtime;
mod sse;
mod write_seal;
pub use runtime::{ProviderExecution, ProviderOutput, ProviderTransport, execute_provider};

#[cfg(test)]
#[path = "../../tests/unit/runtime.rs"]
mod test_runtime;
