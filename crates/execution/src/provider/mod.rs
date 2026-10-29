//! Provider owner facade; request dispatch and output custody stay private.
mod runtime;
mod sse;
pub use runtime::{ProviderExecution, ProviderOutput, ProviderTransport, execute_provider};
