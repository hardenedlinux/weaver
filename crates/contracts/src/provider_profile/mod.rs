//! Source-owned, immutable provider semantics; construction grants no execution rights.
mod artifact;
mod messages;
mod request;
mod sampling;

pub use artifact::{CHAT_TEXT_SSE, ProviderProfile, ProviderRequestFacts};
