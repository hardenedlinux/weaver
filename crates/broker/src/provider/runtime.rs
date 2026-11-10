// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Guarded provider invocation; no retry, redirect, reconnect or automatic route fallback.
use super::{anthropic_sse, openai_sse, wif};
#[cfg(feature = "test-loopback")]
use std::time::Instant;
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
    /// Bounded local diagnostics, never evidence that a send did not happen.
    fn observe_transport(&self, _phases: super::ProviderTransportPhases) {}
    #[cfg(feature = "test-loopback")]
    fn observe_admission(
        &self,
        _enqueue_nanos: u128,
        _consume_nanos: u128,
        _ledger: [weaver_ledger::TransactionTimings; 2],
    ) {}
    #[cfg(feature = "test-loopback")]
    fn observe_dispatch(&self, _prepare_nanos: u128, _dispatch_nanos: u128) {}
    type Slot;
    type PreparedFrame;
    fn stopped(&self) -> bool;
    fn reserve(&mut self) -> Result<Self::Slot>;
    /// Advance local handoffs while waiting for upstream data and return the
    /// original deadline of the oldest pending handoff.
    fn service_delivery(
        &mut self,
        _ledger: &mut Ledger,
        _permit: &ProviderDispatch,
        _format: &str,
    ) -> Result<Option<tokio::time::Instant>> {
        Ok(None)
    }
    /// Poll the oldest pending handoff's state changes on the same reactor.
    fn poll_delivery_ready(&self, _cx: &mut std::task::Context<'_>) -> std::task::Poll<()> {
        std::task::Poll::Pending
    }
    /// Reconcile bounded inert deliveries before waiting for actual output credit.
    fn reserve_for_delivery(
        &mut self,
        _ledger: &mut Ledger,
        _permit: &ProviderDispatch,
        _format: &str,
    ) -> Result<Self::Slot> {
        self.reserve()
    }
    /// Join every pending local handoff before declaring a terminal stream.
    fn drain_delivery(
        &mut self,
        _ledger: &mut Ledger,
        _permit: &ProviderDispatch,
        _format: &str,
    ) -> Result<()> {
        Ok(())
    }

    /// Diagnostic single-range preparation on the explicit test-loopback host.
    #[cfg(feature = "test-loopback")]
    fn prepare_ranges_separately(&self) -> bool {
        false
    }
    /// Safe same-image diagnostic: commit each range through the same group
    /// implementation with width one, without changing collection width.
    #[cfg(feature = "test-loopback")]
    fn release_ranges_separately(&self) -> bool {
        false
    }
    /// Pure bounded encoding. It cannot insert a frame or grant send authority.
    fn prepare(
        route: &ProviderRoute,
        model: &str,
        events: &[ProviderEvent],
        format: &str,
    ) -> Result<Self::PreparedFrame>;
    /// Only this callback may publish the already prepared frame.
    fn emit(
        &mut self,
        slot: Self::Slot,
        frame: Self::PreparedFrame,
        receipt: weaver_ledger::ProviderDelivery,
    ) -> Result<()>;
    /// Acknowledge a committed inert frame outside the deciding scope.
    fn finish_delivery(
        &mut self,
        ledger: &mut Ledger,
        permit: &weaver_ledger::ProviderDispatch,
        format: &str,
    ) -> Result<()>;
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

/// Execute with the current catalog commitment from the authenticated host.
pub fn execute_catalog_provider<O: ProviderOutput>(
    ledger: &mut Ledger,
    request: ProviderExecution<'_>,
    output: &mut O,
    catalog: &str,
) -> Result<()> {
    execute_catalog_provider_with_oauth(
        ledger,
        request,
        output,
        ProviderExecutionAuthority {
            catalog,
            oauth: None,
        },
    )
}

/// Current catalog commitment and delegated caller observation supplied by the host.
pub struct ProviderExecutionAuthority<'a> {
    pub catalog: &'a str,
    pub oauth: Option<&'a weaver_contracts::ProviderOAuthUse>,
}

/// The host's current authority inputs and optional prepared Session successor.
pub struct ProviderExecutionAdmission<'a> {
    pub authority: ProviderExecutionAuthority<'a>,
    pub progression: Option<&'a weaver_ledger::ProviderProgression>,
}

/// Run the provider pipeline with the caller observation from authenticated RPC.
pub fn execute_catalog_provider_with_oauth<O: ProviderOutput>(
    ledger: &mut Ledger,
    request: ProviderExecution<'_>,
    output: &mut O,
    authority: ProviderExecutionAuthority<'_>,
) -> Result<()> {
    execute_provider_progression(
        ledger,
        request,
        output,
        ProviderExecutionAdmission {
            authority,
            progression: None,
        },
    )
}

/// Use the existing provider pipeline with an optional sealed successor proposal.
pub fn execute_provider_progression<O: ProviderOutput>(
    ledger: &mut Ledger,
    request: ProviderExecution<'_>,
    output: &mut O,
    admission: ProviderExecutionAdmission<'_>,
) -> Result<()> {
    if !cfg!(feature = "llm-provider") {
        return Err(Error::Invalid("LLM provider feature disabled"));
    }
    let ProviderExecution {
        plan,
        transport,
        format,
        batch_rows,
    } = request;
    if !(1..=32).contains(&batch_rows)
        || !matches!(format, "protobuf" | "arrow")
        || output.stopped()
    {
        return Err(Error::Invalid("provider response profile or cancellation"));
    }
    for route in &plan.routes {
        crate::HttpsTransport::validate_endpoint(&route.endpoint)?;
    }
    let permit = admit_and_consume(ledger, plan, transport, output, admission)?;
    let result_capture = permit.expects_workflow_result().then(String::new);
    let response = open_guarded(ledger, &permit, transport, output)?;
    let (tokens, response) = super::range_output::relay(
        ledger,
        &permit,
        output,
        response,
        format,
        batch_rows,
        result_capture,
    )?;
    output.drain_delivery(ledger, &permit, format)?;
    ledger.complete_provider_with_result(&permit, format, tokens, response.as_deref())
}

fn admit_and_consume<O: ProviderOutput>(
    ledger: &mut Ledger,
    plan: &ProviderPlan,
    transport: &ProviderTransport,
    output: &O,
    admission: ProviderExecutionAdmission<'_>,
) -> Result<ProviderDispatch> {
    let ProviderExecutionAuthority { catalog, oauth } = admission.authority;
    #[cfg(feature = "test-loopback")]
    let before_enqueue = ledger.transaction_timings();
    #[cfg(feature = "test-loopback")]
    let enqueue_started = Instant::now();
    ledger.enqueue_provider_progression(plan, catalog, oauth, admission.progression)?;
    #[cfg(feature = "test-loopback")]
    let enqueue_nanos = enqueue_started.elapsed().as_nanos();
    #[cfg(feature = "test-loopback")]
    let after_enqueue = ledger.transaction_timings();
    if output.stopped() {
        return Err(Error::Conflict("cancelled before provider consumption"));
    }
    #[cfg(feature = "test-loopback")]
    let consume_started = Instant::now();
    let permit = ledger.consume_provider_with_oauth(
        &plan.family,
        &plan.node,
        &transport.eligible(),
        oauth,
    )?;
    #[cfg(feature = "test-loopback")]
    output.observe_admission(
        enqueue_nanos,
        consume_started.elapsed().as_nanos(),
        [
            after_enqueue.since(before_enqueue),
            ledger.transaction_timings().since(after_enqueue),
        ],
    );
    Ok(permit)
}

pub(super) enum StreamDecoder<R: tokio::io::AsyncRead + Unpin> {
    OpenAi(openai_sse::Decoder<R>),
    Anthropic(anthropic_sse::Decoder<R>),
}

impl<R: tokio::io::AsyncRead + Unpin> StreamDecoder<R> {
    pub(super) fn new(input: R, permit: &ProviderDispatch) -> Self {
        let model = &permit.plan().model;
        match permit.protocol() {
            ProviderProtocol::OpenAi => Self::OpenAi(openai_sse::Decoder::new(input, model)),
            ProviderProtocol::Anthropic => {
                Self::Anthropic(anthropic_sse::Decoder::new(input, model))
            }
        }
    }

    pub(super) async fn next(&mut self) -> Result<ProviderEvent> {
        match self {
            Self::OpenAi(reader) => reader.next().await,
            Self::Anthropic(reader) => reader.next().await,
        }
    }

    pub(super) async fn next_buffered(&mut self) -> Result<Option<ProviderEvent>> {
        match self {
            Self::OpenAi(reader) => reader.next_buffered().await,
            Self::Anthropic(reader) => reader.next_buffered().await,
        }
    }

    pub(super) fn terminal_tokens(&self) -> Option<[u64; 4]> {
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
    #[cfg(feature = "test-loopback")]
    let prepare_started = Instant::now();
    let request = transport
        .prepare(permit.plan(), permit.route(), permit.protocol())?
        .with_oauth_expiration(permit.oauth_expires());
    #[cfg(feature = "test-loopback")]
    let prepare_nanos = prepare_started.elapsed().as_nanos();
    let phases = std::cell::Cell::new(super::ProviderTransportPhases::default());
    let result = (|| {
        #[cfg(feature = "test-loopback")]
        let dispatch_started = Instant::now();
        let sealed = ledger.dispatch_provider(permit, || {
            if output.stopped() {
                return Err(Error::Conflict("cancelled before provider invocation"));
            }
            request.write_and_seal(&phases)
        })?;
        #[cfg(feature = "test-loopback")]
        output.observe_dispatch(prepare_nanos, dispatch_started.elapsed().as_nanos());
        if output.stopped() {
            return Err(Error::Conflict("cancelled after provider seal"));
        }
        sealed.wait_for_response_headers(&phases)
    })();
    output.observe_transport(phases.get());
    result
}

#[cfg(test)]
#[path = "../../tests/unit/provider_dispatch.rs"]
mod dispatch_tests;
