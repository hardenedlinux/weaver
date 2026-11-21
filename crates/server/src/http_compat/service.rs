// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded Tonic HTTP service; the source listener never mounts this service.
use super::{HttpProfile, config::AUTH_HEADERS_CONFLICT};
use crate::grpc::Gateway;
use bytes::Bytes;
use http_body_util::Full;
use std::{
    convert::Infallible,
    future::Future,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use tonic::{
    body::Body,
    codegen::{Service, http},
};
use weaver_contracts::Error;

#[derive(Clone)]
pub(super) struct Compatibility {
    pub gateway: Gateway,
    pub profile: Arc<HttpProfile>,
}
impl tonic::server::NamedService for Compatibility {
    const NAME: &'static str = "v1";
}
impl Service<http::Request<Body>> for Compatibility {
    type Response = http::Response<Body>;
    type Error = Infallible;
    type Future = Pin<Box<dyn Future<Output = Result<Self::Response, Self::Error>> + Send>>;
    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        Poll::Ready(Ok(()))
    }
    fn call(&mut self, request: http::Request<Body>) -> Self::Future {
        let owner = self.clone();
        Box::pin(async move {
            let response = owner.handle(request).await.unwrap_or_else(rejected);
            Ok(response)
        })
    }
}
pub(super) fn json(code: http::StatusCode, value: serde_json::Value) -> http::Response<Body> {
    let mut response = http::Response::new(Body::new(Full::new(Bytes::from(value.to_string()))));
    *response.status_mut() = code;
    response.headers_mut().insert(
        http::header::CONTENT_TYPE,
        http::HeaderValue::from_static("application/json"),
    );
    response.headers_mut().insert(
        http::header::CACHE_CONTROL,
        http::HeaderValue::from_static("no-store"),
    );
    response
}
fn rejected(status: tonic::Status) -> http::Response<Body> {
    use tonic::Code;
    let code = match status.code() {
        Code::Unauthenticated => http::StatusCode::UNAUTHORIZED,
        Code::PermissionDenied => http::StatusCode::FORBIDDEN,
        Code::NotFound => http::StatusCode::NOT_FOUND,
        Code::ResourceExhausted => http::StatusCode::TOO_MANY_REQUESTS,
        Code::Unavailable => http::StatusCode::SERVICE_UNAVAILABLE,
        Code::FailedPrecondition | Code::AlreadyExists => http::StatusCode::CONFLICT,
        Code::DeadlineExceeded => http::StatusCode::REQUEST_TIMEOUT,
        _ => http::StatusCode::BAD_REQUEST,
    };
    let message =
        if status.code() == Code::Unauthenticated && status.message() == AUTH_HEADERS_CONFLICT {
            AUTH_HEADERS_CONFLICT
        } else {
            "Request rejected by Weaver"
        };
    json(
        code,
        serde_json::json!({"type":"error","error":{"type":"weaver_request_rejected","message":message}}),
    )
}
#[cfg(test)]
#[path = "../../tests/unit/http_rejection.rs"]
mod rejection_tests;
pub(crate) async fn serve(
    listener: tokio::net::TcpListener,
    gateway: Gateway,
    profile: HttpProfile,
) -> weaver_contracts::Result<()> {
    if !listener
        .local_addr()
        .map_err(|_| Error::Invalid("HTTP listener"))?
        .ip()
        .is_loopback()
    {
        return Err(Error::Invalid("HTTP loopback required"));
    }
    profile.validate(&gateway)?;
    #[cfg(feature = "magpie")]
    let _connection = crate::magpie::bind(&profile, &gateway).await?;
    let runtime = gateway.runtime.clone();
    tonic::transport::Server::builder()
        .accept_http1(true)
        .timeout(std::time::Duration::from_secs(10))
        .max_concurrent_streams(32)
        .concurrency_limit_per_connection(32)
        .http2_max_header_list_size(8192)
        .initial_stream_window_size(65536)
        .initial_connection_window_size(1048576)
        .add_service(Compatibility {
            gateway,
            profile: Arc::new(profile),
        })
        .serve_with_incoming_shutdown(
            crate::connections::Incoming::new(
                listener,
                Arc::new(tokio::sync::Semaphore::new(
                    crate::connections::MAX_CONNECTIONS,
                )),
            ),
            async move {
                runtime.cancellation().await;
            },
        )
        .await
        .map_err(|_| Error::Conflict("HTTP listener failed"))
}
