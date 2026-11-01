//! Bounded source compilation on the caller's tracked blocking owner.
mod client;
mod owner;
mod request;
mod state;
pub use client::{SourceClient, source_lane};
pub use owner::SourceInbox;
pub use request::{SourceJob, SourceJobError};
use state::{Command, Phase, Reply, Shared, State, Work};
