//! Bounded authenticated owner API; no network location grants original-task authority.
use crate::{ServerConfig, operations};
use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Extension, Path, Request, State},
    http::{HeaderMap, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use subtle::ConstantTimeEq;
use tokio::{
    net::TcpListener,
    sync::{OwnedSemaphorePermit, Semaphore},
};
use weaver_contracts::{Error, MAX_BODY_BYTES, Result};

#[derive(Clone)]
struct App {
    config: ServerConfig,
    slots: Arc<Semaphore>,
    runtime: crate::runtime::RuntimeOwner,
}
type Key = (String, String, String);
type Slot = Arc<OwnedSemaphorePermit>;

/// Serve the explicit local owner profile; remote plaintext listeners are rejected.
pub async fn serve(listener: TcpListener, config: ServerConfig) -> Result<()> {
    serve_with_shutdown(listener, config, std::future::pending()).await
}
/// Stop new admission and wait for tracked native writers before acknowledging shutdown.
pub async fn serve_with_shutdown(
    listener: TcpListener,
    config: ServerConfig,
    shutdown: impl std::future::Future<Output = ()> + Send + 'static,
) -> Result<()> {
    config.validate()?;
    if !listener
        .local_addr()
        .map_err(|e| Error::Storage(e.to_string()))?
        .ip()
        .is_loopback()
    {
        return Err(Error::Invalid("owner API requires loopback"));
    }
    let runtime = crate::runtime::RuntimeOwner::new();
    let state = App {
        runtime: runtime.clone(),
        slots: Arc::new(Semaphore::new(config.max_in_flight)),
        config,
    };
    let closing = runtime.clone();
    let result = axum::serve(listener, router(state))
        .with_graceful_shutdown(async move {
            shutdown.await;
            closing.request_shutdown();
        })
        .await;
    runtime.drain().await;
    result.map_err(|e| Error::Storage(e.to_string()))
}
/// Load required identity configuration and start the local deployment entrypoint.
pub async fn run_http_from_env() -> Result<()> {
    let config = crate::config::from_env()?;
    config.validate()?;
    let shutdown = crate::shutdown::signal()?;
    let address: std::net::SocketAddr = std::env::var("WEAVER_LISTEN")
        .unwrap_or_else(|_| "127.0.0.1:18080".into())
        .parse()
        .map_err(|_| Error::Invalid("listener address"))?;
    if !address.ip().is_loopback() {
        return Err(Error::Invalid("owner API requires loopback"));
    }
    let listener = TcpListener::bind(address)
        .await
        .map_err(|e| Error::Storage(e.to_string()))?;
    serve_with_shutdown(listener, config, shutdown).await
}
fn router(state: App) -> Router {
    let protected = Router::new()
        .route("/v1/messages", post(enqueue))
        .route("/v1/messages/{family}/{node}/{message}", get(lookup))
        .route("/v1/messages/{family}/{node}/{message}/send", post(send))
        .route_layer(middleware::from_fn_with_state(state.clone(), admit))
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES * 2));
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .merge(protected)
        .with_state(state)
}
async fn admit(State(state): State<App>, mut request: Request, next: Next) -> Response {
    if state.runtime.closing() {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }
    if !authenticated(request.headers(), &state.config.token_sha256) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Ok(slot) = state.slots.clone().try_acquire_owned() else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    request.extensions_mut().insert(Arc::new(slot));
    tokio::select! {
        biased;
        _ = state.runtime.cancelled() => StatusCode::SERVICE_UNAVAILABLE.into_response(),
        response = next.run(request) => response,
    }
}
fn authenticated(headers: &HeaderMap, expected: &[u8; 32]) -> bool {
    if headers.get_all("authorization").iter().count() != 1 {
        return false;
    }
    let Some(token) = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
    else {
        return false;
    };
    if token.is_empty() || token.len() > 256 {
        return false;
    }
    let actual: [u8; 32] = Sha256::digest(token.as_bytes()).into();
    bool::from(actual.ct_eq(expected))
}
async fn enqueue(
    State(state): State<App>,
    Extension(slot): Extension<Slot>,
    body: Bytes,
) -> Response {
    let Ok(message) = weaver_contracts::decode(&body) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    native(&state.runtime, slot, move |_| {
        operations::enqueue(&state.config, message)
    })
    .await
}
async fn lookup(
    State(state): State<App>,
    Extension(slot): Extension<Slot>,
    Path(key): Path<Key>,
) -> Response {
    native(&state.runtime, slot, move |_| {
        operations::lookup(&state.config, key)
    })
    .await
}
async fn send(
    State(state): State<App>,
    Extension(slot): Extension<Slot>,
    Path(key): Path<Key>,
    body: Bytes,
) -> Response {
    let Ok(request) = weaver_contracts::decode(&body) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    native(&state.runtime, slot, move |cancel| {
        operations::send(&state.config, key, request, cancel)
    })
    .await
}
async fn native<T: serde::Serialize + Send + 'static>(
    runtime: &crate::runtime::RuntimeOwner,
    slot: Slot,
    run: impl FnOnce(tokio_util::sync::CancellationToken) -> Result<T> + Send + 'static,
) -> Response {
    let Ok(job) = runtime.spawn_blocking(slot, run) else {
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    };
    match job.await {
        Ok(Ok(value)) => Json(value).into_response(),
        Ok(Err(Error::Denied)) => StatusCode::FORBIDDEN.into_response(),
        _ => StatusCode::CONFLICT.into_response(),
    }
}
