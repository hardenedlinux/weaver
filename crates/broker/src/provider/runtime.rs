// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Guarded provider invocation; no retry, redirect, reconnect or automatic route fallback.
use super::{anthropic_sse, openai_sse, wif};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
};
use weaver_contracts::{
    Error, ProviderEvent, ProviderPlan, ProviderProtocol, ProviderRoute, Result,
};
use weaver_ledger::{Ledger, ProviderDispatch};

/// Process-owned provider credentials and a bounded, non-retrying HTTPS client.
#[derive(Clone)]
pub struct ProviderTransport {
    inner: Arc<Settings>,
}
struct Settings {
    credentials: BTreeMap<String, String>,
    federation: BTreeMap<String, wif::Federation>,
    exchange_client: Option<reqwest::Client>,
    tls: Arc<rustls::ClientConfig>,
    runtime: Arc<super::io_runtime::IoRuntime>,
    #[cfg(feature = "test-loopback")]
    loopback: Option<std::net::SocketAddr>,
}
impl ProviderTransport {
    /// Blocking execution borrows the embedding owner's live reactor. The host
    /// must drain its tracked requests before shutting that reactor down.
    pub fn new(
        credentials: BTreeMap<String, String>,
        root_pem: Option<&[u8]>,
        reactor: tokio::runtime::Handle,
    ) -> Result<Self> {
        Self::with_anthropic_wif(credentials, BTreeMap::new(), root_pem, reactor)
    }

    pub fn with_anthropic_wif(
        credentials: BTreeMap<String, String>,
        wif: BTreeMap<String, wif::AnthropicWifConfig>,
        root_pem: Option<&[u8]>,
        reactor: tokio::runtime::Handle,
    ) -> Result<Self> {
        Self::build(
            credentials,
            wif,
            root_pem,
            reactor,
            #[cfg(feature = "test-loopback")]
            None,
        )
    }

    /// Bind the canonical Anthropic authority to one test-only loopback peer.
    #[cfg(feature = "test-loopback")]
    #[doc(hidden)]
    pub fn with_wif_loopback(
        wif: BTreeMap<String, wif::AnthropicWifConfig>,
        root_pem: &[u8],
        reactor: tokio::runtime::Handle,
        loopback: std::net::SocketAddr,
    ) -> Result<Self> {
        if !loopback.ip().is_loopback() || loopback.port() == 0 || wif.is_empty() {
            return Err(Error::Invalid("WIF test peer"));
        }
        Self::build(
            BTreeMap::new(),
            wif,
            Some(root_pem),
            reactor,
            Some(loopback),
        )
    }

    fn build(
        credentials: BTreeMap<String, String>,
        wif: BTreeMap<String, wif::AnthropicWifConfig>,
        root_pem: Option<&[u8]>,
        reactor: tokio::runtime::Handle,
        #[cfg(feature = "test-loopback")] loopback: Option<std::net::SocketAddr>,
    ) -> Result<Self> {
        if credentials.len().saturating_add(wif.len()) > 8 {
            return Err(Error::Invalid("provider credential bound"));
        }
        let mut federation = BTreeMap::new();
        for (target, config) in wif {
            weaver_contracts::identifier(&target)?;
            if credentials.contains_key(&target) {
                return Err(Error::Invalid("ambiguous provider credential"));
            }
            federation.insert(target, wif::Federation::new(config)?);
        }
        for (target, secret) in &credentials {
            weaver_contracts::identifier(target)?;
            if secret.is_empty()
                || secret.len() > 4096
                || !secret.bytes().all(|b| b.is_ascii_graphic())
            {
                return Err(Error::Invalid("provider credential"));
            }
        }
        use rustls::pki_types::pem::PemObject;
        use rustls_platform_verifier::BuilderVerifierExt;
        let builder = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .map_err(|_| Error::Invalid("provider TLS protocols"))?;
        let mut tls = if let Some(pem) = root_pem {
            let mut roots = rustls::RootCertStore::empty();
            for certificate in rustls::pki_types::CertificateDer::pem_slice_iter(pem) {
                roots
                    .add(certificate.map_err(|_| Error::Invalid("provider trust root"))?)
                    .map_err(|_| Error::Invalid("provider trust root"))?;
            }
            if roots.is_empty() {
                return Err(Error::Invalid("provider trust root"));
            }
            builder.with_root_certificates(roots).with_no_client_auth()
        } else {
            builder
                .with_platform_verifier()
                .map_err(|_| Error::Invalid("provider platform trust"))?
                .with_no_client_auth()
        };
        tls.alpn_protocols = vec![b"http/1.1".to_vec()];
        let exchange_client = if federation.is_empty() {
            None
        } else {
            let _reactor = reactor.enter();
            let client = reqwest::Client::builder()
                .https_only(true)
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .retry(reqwest::retry::never())
                .tls_backend_preconfigured(tls.clone());
            #[cfg(feature = "test-loopback")]
            let client = if let Some(peer) = loopback {
                client.resolve("api.anthropic.com", peer)
            } else {
                client
            };
            Some(
                client
                    .build()
                    .map_err(|_| Error::Invalid("WIF HTTPS client"))?,
            )
        };
        Ok(Self {
            inner: Arc::new(Settings {
                credentials,
                federation,
                exchange_client,
                tls: Arc::new(tls),
                runtime: Arc::new(super::io_runtime::IoRuntime { handle: reactor }),
                #[cfg(feature = "test-loopback")]
                loopback,
            }),
        })
    }
    fn eligible(&self) -> BTreeSet<String> {
        self.inner
            .credentials
            .keys()
            .chain(self.inner.federation.keys())
            .cloned()
            .collect()
    }
    fn prepare(
        &self,
        plan: &ProviderPlan,
        route: &ProviderRoute,
        protocol: ProviderProtocol,
    ) -> Result<super::request::PreparedRequest> {
        crate::HttpsTransport::validate_endpoint(&route.endpoint)?;
        let runtime = self.inner.runtime.clone();
        let token = if let Some(federation) = self.inner.federation.get(&route.target) {
            if !matches!(protocol, ProviderProtocol::Anthropic) || route.endpoint != wif::MESSAGES {
                return Err(Error::Denied);
            }
            let client = self.inner.exchange_client.as_ref().ok_or(Error::Denied)?;
            Some(federation.token(client, &runtime)?)
        } else {
            None
        };
        let secret = match &token {
            Some(token) => token.value.as_ref(),
            None => self
                .inner
                .credentials
                .get(&route.target)
                .ok_or(Error::Denied)?
                .as_str(),
        };
        let request = super::request::PreparedRequest::new(
            &route.endpoint,
            secret,
            protocol,
            token.as_ref().map(|token| token.expires),
            &plan.body,
            self.inner.tls.clone(),
            runtime,
        )?;
        #[cfg(feature = "test-loopback")]
        let request = request.with_loopback(token.and(self.inner.loopback));
        Ok(request)
    }
}
/// Starts at most one source-bound request. The callback receives bounded batches only
/// under a fresh Cedar release guard; its error leaves the release and budget unknown.
pub trait ProviderOutput {
    type Slot;
    type PreparedFrame;
    fn stopped(&self) -> bool;
    fn reserve(&mut self) -> Result<Self::Slot>;
    /// Pure bounded encoding. It cannot insert a frame or grant send authority.
    fn prepare(
        route: &ProviderRoute,
        model: &str,
        events: &[ProviderEvent],
        format: &str,
    ) -> Result<Self::PreparedFrame>;
    /// Only this callback may publish the already prepared frame.
    fn emit(&mut self, slot: Self::Slot, frame: Self::PreparedFrame) -> Result<()>;
}
/// Named execution inputs keep route authority distinct from output queue custody.
pub struct ProviderExecution<'a> {
    pub plan: &'a ProviderPlan,
    pub transport: &'a ProviderTransport,
    pub format: &'a str,
    pub batch_rows: usize,
}
/// Validate the response profile, then run the consumed provider pipeline once.
pub fn execute_provider<O: ProviderOutput>(
    ledger: &mut Ledger,
    request: ProviderExecution<'_>,
    output: &mut O,
) -> Result<()> {
    execute_catalog_provider(ledger, request, output, "")
}

pub fn execute_catalog_provider<O: ProviderOutput>(
    ledger: &mut Ledger,
    request: ProviderExecution<'_>,
    output: &mut O,
    catalog: &str,
) -> Result<()> {
    if !cfg!(feature = "llm-provider") {
        return Err(Error::Invalid("LLM provider feature disabled"));
    }
    execute_stream(
        ledger,
        request.plan,
        request.transport,
        request.format,
        request.batch_rows,
        output,
        catalog,
    )
}
fn execute_stream<O: ProviderOutput>(
    ledger: &mut Ledger,
    plan: &ProviderPlan,
    transport: &ProviderTransport,
    format: &str,
    batch_rows: usize,
    output: &mut O,
    catalog: &str,
) -> Result<()> {
    if !(1..=32).contains(&batch_rows)
        || !matches!(format, "protobuf" | "arrow")
        || output.stopped()
    {
        return Err(Error::Invalid("provider response profile or cancellation"));
    }
    for route in &plan.routes {
        crate::HttpsTransport::validate_endpoint(&route.endpoint)?;
    }
    ledger.enqueue_catalog_provider(plan, catalog)?;
    if output.stopped() {
        return Err(Error::Conflict("cancelled before provider consumption"));
    }
    let permit = ledger.consume_provider(&plan.family, &plan.node, &transport.eligible())?;
    let response = open_guarded(ledger, &permit, transport, output)?;
    let mut reader = match permit.protocol() {
        ProviderProtocol::OpenAi => {
            StreamDecoder::OpenAi(openai_sse::Decoder::new(response, &plan.model))
        }
        ProviderProtocol::Anthropic => {
            StreamDecoder::Anthropic(anthropic_sse::Decoder::new(response, &plan.model))
        }
    };
    let mut batch = Vec::with_capacity(batch_rows);
    loop {
        if output.stopped() {
            return Err(Error::Conflict("provider response cancelled"));
        }
        let event = reader.next()?;
        let terminal = event.kind == weaver_contracts::ProviderEventKind::Done;
        batch.push(event);
        if terminal || batch.len() == batch_rows {
            // Flow-control capacity is reserved outside the deciding write lock.
            let slot = output.reserve()?;
            let digest = weaver_contracts::body_digest(&serde_json::to_string(&batch)?);
            let release =
                ledger.prepare_provider_release(&permit, &digest, format, batch.len() as u64)?;
            if output.stopped() {
                return Err(Error::Conflict("provider release cancelled"));
            }
            let first = release.first_sequence();
            for (offset, event) in batch.iter_mut().enumerate() {
                event.sequence = first + offset as u64;
            }
            let frame = O::prepare(permit.route(), &plan.model, &batch, format)?;
            ledger.release_provider(&permit, release, format, |actual| {
                if actual != first || output.stopped() {
                    return Err(Error::Conflict("provider release cancelled or rebound"));
                }
                output.emit(slot, frame)
            })?;
            batch.clear();
        }
        if terminal {
            break;
        }
    }
    ledger.complete_provider_with_usage(&permit, format, reader.terminal_tokens())
}

enum StreamDecoder<R: std::io::Read> {
    OpenAi(openai_sse::Decoder<R>),
    Anthropic(anthropic_sse::Decoder<R>),
}

impl<R: std::io::Read> StreamDecoder<R> {
    fn next(&mut self) -> Result<ProviderEvent> {
        match self {
            Self::OpenAi(reader) => reader.next(),
            Self::Anthropic(reader) => reader.next(),
        }
    }

    fn terminal_tokens(&self) -> Option<[u64; 4]> {
        match self {
            Self::OpenAi(reader) => reader.terminal_tokens,
            Self::Anthropic(reader) => Some(reader.tokens()),
        }
    }
}

fn open_guarded<O: ProviderOutput>(
    ledger: &mut Ledger,
    permit: &ProviderDispatch,
    transport: &ProviderTransport,
    output: &O,
) -> Result<super::response::Response> {
    if output.stopped() {
        return Err(Error::Conflict("cancelled after provider consumption"));
    }
    // WIF exchange and request preparation occur outside the deciding send scope.
    let request = transport.prepare(permit.plan(), permit.route(), permit.protocol())?;
    let sealed = ledger.dispatch_provider(permit, || {
        if output.stopped() {
            return Err(Error::Conflict("cancelled before provider invocation"));
        }
        request.write_and_seal()
    })?;
    if output.stopped() {
        return Err(Error::Conflict("cancelled after provider seal"));
    }
    sealed.wait_for_response_headers()
}

#[cfg(test)]
#[path = "../../tests/unit/provider_dispatch.rs"]
mod dispatch_tests;
