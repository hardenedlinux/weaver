//! Private native transport owners; no unguarded send API leaves execution.
pub(crate) mod https;
pub(crate) mod stream_sink;
pub(crate) mod stream_socket;
