// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Immutable preparation is inert. Connect, TLS and request sealing stay guarded.
use super::{
    io_runtime::IoRuntime,
    response::{Driver, SealedRequest},
    write_seal::{WRITING, WriteSeal},
};
use bytes::Bytes;
use http_body_util::Full;
use hyper::{Request, client::conn::http1};
use hyper_util::rt::TokioIo;
use std::{
    sync::{Arc, atomic::AtomicU8},
    time::Duration,
};
use tokio::{
    net::TcpStream,
    time::{Instant, timeout},
};
use tokio_rustls::TlsConnector;
use weaver_contracts::{Error, Result};
pub(super) struct PreparedRequest {
    request: Request<Full<Bytes>>,
    host: String,
    port: u16,
    length: usize,
    tls: Arc<rustls::ClientConfig>,
    runtime: Arc<IoRuntime>,
}
impl PreparedRequest {
    pub(super) fn new(
        endpoint: &str,
        secret: &str,
        body: &str,
        tls: Arc<rustls::ClientConfig>,
        runtime: Arc<IoRuntime>,
    ) -> Result<Self> {
        let url = reqwest::Url::parse(endpoint).map_err(|_| Error::Invalid("provider endpoint"))?;
        let host = url
            .host_str()
            .ok_or(Error::Invalid("provider host"))?
            .trim_start_matches('[')
            .trim_end_matches(']')
            .to_owned();
        let port = url
            .port_or_known_default()
            .ok_or(Error::Invalid("provider port"))?;
        let uri: hyper::Uri = endpoint
            .parse()
            .map_err(|_| Error::Invalid("provider URI"))?;
        let authority = uri
            .authority()
            .ok_or(Error::Invalid("provider authority"))?
            .as_str();
        let mut authorization = hyper::header::HeaderValue::try_from(format!("Bearer {secret}"))
            .map_err(|_| Error::Invalid("provider authorization"))?;
        authorization.set_sensitive(true);
        let request = Request::builder()
            .method("POST")
            .uri(uri.path_and_query().map_or("/", |p| p.as_str()))
            .header("Host", authority)
            .header("Authorization", authorization)
            .header("Content-Type", "application/json")
            .header("Accept", "text/event-stream")
            .header("Content-Length", body.len())
            .header("Connection", "close")
            .body(Full::new(Bytes::copy_from_slice(body.as_bytes())))
            .map_err(|_| Error::Invalid("provider request construction"))?;
        Ok(Self {
            request,
            host,
            port,
            length: body.len(),
            tls,
            runtime,
        })
    }
    pub(super) fn write_and_seal(self) -> Result<SealedRequest> {
        let runtime = self.runtime.clone();
        let deadline = Instant::now() + Duration::from_secs(10);
        runtime.wait(deadline, async move {
            let name = rustls::pki_types::ServerName::try_from(self.host.clone())
                .map_err(|_| Error::Invalid("provider TLS name"))?;
            let stream = timeout(Duration::from_secs(3), async {
                let tcp = TcpStream::connect((self.host.as_str(), self.port)).await?;
                tcp.set_nodelay(true)?;
                TlsConnector::from(self.tls).connect(name, tcp).await
            })
            .await
            .map_err(|_| Error::Conflict("provider connect unknown"))?
            .map_err(|_| Error::Conflict("provider connect unknown"))?;
            let phase = Arc::new(AtomicU8::new(WRITING));
            let io = TokioIo::new(WriteSeal::new(stream, self.length, phase.clone()));
            let (mut sender, connection) = http1::Builder::new()
                .max_buf_size(65536)
                .handshake(io)
                .await
                .map_err(|_| Error::Conflict("provider HTTP unknown"))?;
            let response = Box::pin(async move { sender.send_request(self.request).await });
            SealedRequest::finish_writing(
                Driver::new(connection),
                response,
                phase,
                self.runtime,
                deadline,
            )
            .await
        })
    }
}

#[cfg(test)]
#[path = "../../tests/unit/provider_request.rs"]
mod tests;
