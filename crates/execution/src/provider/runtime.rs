//! Guarded provider invocation; no retry, redirect, reconnect or automatic route fallback.
use super::sse;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
};
use weaver_contracts::{Error, ProviderEvent, ProviderPlan, ProviderRoute, Result};
use weaver_ledger::{Ledger, ProviderDispatch};

/// Process-owned provider credentials and a bounded, non-retrying HTTPS client.
#[derive(Clone)]
pub struct ProviderTransport {
    inner: Arc<Settings>,
}
struct Settings {
    credentials: BTreeMap<String, String>,
    tls: Arc<rustls::ClientConfig>,
    runtime: Arc<super::io_runtime::IoRuntime>,
}
impl ProviderTransport {
    /// Blocking execution borrows the embedding owner's live reactor. The host
    /// must drain its tracked requests before shutting that reactor down.
    pub fn new(
        credentials: BTreeMap<String, String>,
        root_pem: Option<&[u8]>,
        reactor: tokio::runtime::Handle,
    ) -> Result<Self> {
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
        Ok(Self {
            inner: Arc::new(Settings {
                credentials,
                tls: Arc::new(tls),
                runtime: Arc::new(super::io_runtime::IoRuntime { handle: reactor }),
            }),
        })
    }
    fn eligible(&self) -> BTreeSet<String> {
        self.inner.credentials.keys().cloned().collect()
    }
    fn prepare(
        &self,
        plan: &ProviderPlan,
        route: &ProviderRoute,
    ) -> Result<super::request::PreparedRequest> {
        crate::HttpsTransport::validate_endpoint(&route.endpoint)?;
        let runtime = self.inner.runtime.clone();
        let secret = self
            .inner
            .credentials
            .get(&route.target)
            .ok_or(Error::Denied)?;
        super::request::PreparedRequest::new(
            &route.endpoint,
            secret,
            &plan.body,
            self.inner.tls.clone(),
            runtime,
        )
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
    execute_stream(
        ledger,
        request.plan,
        request.transport,
        request.format,
        request.batch_rows,
        output,
    )
}
fn execute_stream<O: ProviderOutput>(
    ledger: &mut Ledger,
    plan: &ProviderPlan,
    transport: &ProviderTransport,
    format: &str,
    batch_rows: usize,
    output: &mut O,
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
    ledger.enqueue_provider(plan)?;
    if output.stopped() {
        return Err(Error::Conflict("cancelled before provider consumption"));
    }
    let permit = ledger.consume_provider(&plan.family, &plan.node, &transport.eligible())?;
    let response = open_guarded(ledger, &permit, transport, output)?;
    let mut reader = sse::Decoder::new(response, &plan.model);
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
    ledger.complete_provider(&permit, format)
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
    // Request construction and local client initialization perform no provider IO.
    let request = transport.prepare(permit.plan(), permit.route())?;
    let sealed = ledger.dispatch_provider(permit, || {
        if output.stopped() {
            return Err(Error::Conflict("cancelled before provider invocation"));
        }
        request.write_and_seal()
    })??;
    if output.stopped() {
        return Err(Error::Conflict("cancelled after provider seal"));
    }
    sealed.wait_for_response_headers()
}

#[cfg(test)]
#[path = "../../tests/unit/provider_dispatch.rs"]
mod dispatch_tests;
