//! Private synchronous sinks; no FD, TLS buffer or asynchronous callback escapes custody.
use crate::transport::stream_socket::DeadlineSocket;
use std::{
    io::Write,
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant},
};
use weaver_contracts::{Error, Result, WriteObservation};

/// Trusted resolver and trust-root input; never constructed from agent request scope.
pub struct StreamTlsConfig {
    pub address: SocketAddr,
    pub root_certificates: Vec<Vec<u8>>,
}
pub(crate) enum OwnedSink {
    Tcp(DeadlineSocket),
    Tls(Box<rustls::StreamOwned<rustls::ClientConnection, DeadlineSocket>>),
}
impl OwnedSink {
    pub(crate) fn tcp(destination: &str) -> Result<Self> {
        let address: SocketAddr = destination
            .strip_prefix("tcp://")
            .ok_or(Error::Invalid("TCP destination"))?
            .parse()
            .map_err(|_| Error::Invalid("TCP address"))?;
        if !address.ip().is_loopback() {
            return Err(Error::Invalid(
                "plaintext is limited to loopback qualification",
            ));
        }
        Ok(Self::Tcp(
            DeadlineSocket::connect(address).map_err(|_| Error::Invalid("TCP connect"))?,
        ))
    }
    pub(crate) fn tls(destination: &str, config: StreamTlsConfig) -> Result<Self> {
        let url =
            reqwest::Url::parse(destination).map_err(|_| Error::Invalid("TLS destination"))?;
        if url.scheme() != "tls"
            || url.port() != Some(config.address.port())
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || !url.path().is_empty()
        {
            return Err(Error::Invalid("TLS destination binding"));
        }
        let host = url
            .host_str()
            .ok_or(Error::Invalid("TLS hostname"))?
            .to_owned();
        let name = rustls::pki_types::ServerName::try_from(host)
            .map_err(|_| Error::Invalid("TLS server name"))?;
        let mut roots = rustls::RootCertStore::empty();
        for bytes in config.root_certificates {
            roots
                .add(rustls::pki_types::CertificateDer::from(bytes))
                .map_err(|_| Error::Invalid("TLS trust root"))?;
        }
        let configuration = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .map_err(|_| Error::Invalid("TLS protocols"))?
        .with_root_certificates(roots)
        .with_no_client_auth();
        let connection = rustls::ClientConnection::new(Arc::new(configuration), name)
            .map_err(|_| Error::Invalid("TLS client"))?;
        let mut stream = rustls::StreamOwned::new(
            connection,
            DeadlineSocket::connect(config.address).map_err(|_| Error::Invalid("TLS connect"))?,
        );
        while stream.conn.is_handshaking() {
            stream
                .conn
                .complete_io(&mut stream.sock)
                .map_err(|_| Error::Invalid("TLS handshake"))?;
        }
        Ok(Self::Tls(Box::new(stream)))
    }
    pub(crate) fn write_once(&mut self, bytes: &[u8]) -> WriteObservation {
        self.socket().deadline = Instant::now() + Duration::from_secs(1);
        let outcome = match self {
            Self::Tcp(s) => observe(s.write(bytes), bytes.len()),
            Self::Tls(s) => {
                let written = s.write(bytes);
                if s.flush().is_err() || s.conn.wants_write() {
                    WriteObservation::Unknown
                } else {
                    observe(written, bytes.len())
                }
            }
        };
        if outcome != WriteObservation::Complete {
            self.close();
        }
        outcome
    }
    pub(crate) fn close(&self) {
        match self {
            Self::Tcp(s) => s.close(),
            Self::Tls(s) => s.sock.close(),
        }
    }
    pub(crate) fn socket(&mut self) -> &mut DeadlineSocket {
        match self {
            Self::Tcp(s) => s,
            Self::Tls(s) => &mut s.sock,
        }
    }
}
fn observe(result: std::io::Result<usize>, length: usize) -> WriteObservation {
    match result {
        Ok(n) if n == length => WriteObservation::Complete,
        Ok(n) => WriteObservation::Partial(n as u64),
        Err(_) => WriteObservation::Unknown,
    }
}
impl Drop for OwnedSink {
    fn drop(&mut self) {
        self.close();
    }
}
