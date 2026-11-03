// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Broker-owned connections; each bounded range rejoins durable current authority.
use crate::transport::stream_sink::{OwnedSink, StreamTlsConfig};
use weaver_contracts::{Error, Result, WriteObservation};
use weaver_ledger::{Ledger, StreamOwner};

use weaver_ledger::StreamClaim as OpenStream;

/// Exclusive live stream; callers never receive its FD, writable buffers or raw sink.
pub struct StreamSession {
    owner: StreamOwner,
    sink: Option<OwnedSink>,
}
impl StreamSession {
    /// Open a source-bound loopback socket for native qualification, never remote plaintext.
    pub fn open_tcp(ledger: &mut Ledger, request: OpenStream<'_>) -> Result<Self> {
        let mut owner = claim(ledger, &request)?;
        let sink = ledger.connect_stream(&mut owner, OwnedSink::tcp)?;
        Ok(Self {
            owner,
            sink: Some(sink),
        })
    }
    /// Open a hostname-verified TLS connection using the trusted resolver and trust roots.
    pub fn open_tls(
        ledger: &mut Ledger,
        request: OpenStream<'_>,
        config: StreamTlsConfig,
    ) -> Result<Self> {
        let mut owner = claim(ledger, &request)?;
        let sink = ledger.connect_stream(&mut owner, |destination| {
            OwnedSink::tls(destination, config)
        })?;
        Ok(Self {
            owner,
            sink: Some(sink),
        })
    }
    /// Consume and send one bounded range; unsupported or uncertain continuations stay closed.
    pub fn send_next(
        &mut self,
        ledger: &mut Ledger,
        message: &str,
        max_bytes: usize,
    ) -> Result<WriteObservation> {
        if self.sink.is_none() {
            return Err(Error::Conflict("stream connection closed"));
        }
        let result = ledger
            .consume_range(&self.owner, message, max_bytes)
            .and_then(|permit| {
                let sink = self
                    .sink
                    .as_mut()
                    .ok_or(Error::Conflict("stream connection closed"))?;
                ledger.write_range(&self.owner, permit, |bytes| sink.write_once(bytes))
            });
        if !matches!(result, Ok(WriteObservation::Complete)) {
            self.close();
        }
        result
    }
    /// Reauthorize only a known unsent original message, without changing its hold or content.
    pub fn resume_message(
        &mut self,
        ledger: &mut Ledger,
        message: &str,
        revision: u64,
        fence: u64,
    ) -> Result<()> {
        if self.sink.is_none() {
            return Err(Error::Conflict("stream connection closed"));
        }
        ledger.resume_message(&self.owner, message, revision, fence)
    }
    /// Shut down before discarding any private sink state; this never releases a reservation.
    pub fn close(&mut self) {
        if let Some(sink) = self.sink.take() {
            sink.close();
        }
    }
}
fn claim(ledger: &mut Ledger, r: &OpenStream<'_>) -> Result<StreamOwner> {
    ledger.claim_stream(OpenStream {
        family: r.family,
        node: r.node,
        destination: r.destination,
        revision: r.revision,
        fence: r.fence,
    })
}

#[cfg(test)]
#[path = "../../tests/unit/stream_wire.rs"]
mod tests;
