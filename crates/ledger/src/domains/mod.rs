//! Authoritative origins and shared budget/history domains.
mod binding;
mod evidence;
mod migration;
mod view;
pub(crate) use binding::bind;
pub(crate) use evidence::{charge, history, require};
pub(crate) use view::{lock_keys, require_stamp, stamp, view};
