//! Provider owner facade; request dispatch and output custody stay private.
mod io_runtime;
mod request;
mod response;
mod runtime;
mod sse;
mod write_seal;
pub use runtime::{ProviderExecution, ProviderOutput, ProviderTransport, execute_provider};

#[cfg(test)]
#[path = "../../tests/support/runtime.rs"]
mod test_runtime;
