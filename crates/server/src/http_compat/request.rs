// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Authenticate first, then observe and admit through the existing source lane.
use super::service::{Compatibility, json};
use http_body_util::{BodyExt, StreamBody};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tokio_stream::StreamExt;
use tonic::{Status, body::Body, codegen::http};
use weaver_contracts::{
    ANTHROPIC_TURN_SSE, CHAT_TURN_SSE, ProviderTurnSubmission, RESPONSES_TURN_SSE,
};

impl Compatibility {
    pub(super) async fn handle(
        &self,
        request: http::Request<Body>,
    ) -> Result<http::Response<Body>, Status> {
        if self.gateway.runtime.closing() {
            return Err(Status::unavailable("server closing"));
        }
        authenticate(request.headers(), &self.profile.token_sha256)?;
        if request.uri().query().is_some() {
            return Err(Status::invalid_argument("query unsupported"));
        }
        let path = request.uri().path();
        let protocol = match (request.method(), path) {
            (&http::Method::GET, "/v1/models") => None,
            (&http::Method::POST, "/v1/chat/completions") => Some(CHAT_TURN_SSE),
            (&http::Method::POST, "/v1/responses") => Some(RESPONSES_TURN_SSE),
            (&http::Method::POST, "/v1/messages") => Some(ANTHROPIC_TURN_SSE),
            _ => return Err(Status::not_found("operation endpoint unavailable")),
        };
        let slot = self.gateway.admission.execution()?;
        let catalog = self
            .gateway
            .routing
            .session_catalog(
                self.profile.session.clone(),
                self.gateway.config.principal.clone(),
            )
            .await?;
        let Some(protocol) = protocol else {
            let models: Vec<_> = catalog.models.iter().map(|model| serde_json::json!({"id":model,"object":"model","created":0,"owned_by":"weaver"})).collect();
            let mut response = json(
                http::StatusCode::OK,
                serde_json::json!({"object":"list","data":models}),
            );
            response.headers_mut().insert(
                "weaver-catalog-version",
                catalog
                    .version
                    .parse()
                    .map_err(|_| Status::internal("catalog version"))?,
            );
            return Ok(response);
        };
        if catalog.profile.protocol != protocol || !cfg!(feature = "llm-provider") {
            return Err(Status::failed_precondition("source protocol differs"));
        }
        if request
            .headers()
            .get_all(http::header::CONTENT_TYPE)
            .iter()
            .count()
            != 1
            || !request
                .headers()
                .get(http::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .is_some_and(|v| {
                    v.split(';')
                        .next()
                        .is_some_and(|kind| kind.trim().eq_ignore_ascii_case("application/json"))
                })
            || request
                .headers()
                .contains_key(http::header::CONTENT_ENCODING)
        {
            return Err(Status::invalid_argument("JSON request required"));
        }
        let operation_id = operation_id(request.headers())?;
        let body = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            read_body(request.into_body(), catalog.profile.max_body_bytes),
        )
        .await
        .map_err(|_| Status::deadline_exceeded("request body deadline"))??;
        let derived = self
            .gateway
            .routing
            .admit_turn(
                &self.gateway.runtime,
                weaver_ledger::ProviderSessionRequest {
                    session: self.profile.session.clone(),
                    principal: self.gateway.config.principal.clone(),
                    submission: ProviderTurnSubmission { operation_id, body },
                },
            )
            .await?;
        // Admission rechecks the exact current source cut. An intervening profile
        // replacement must not change the protocol selected by this HTTP path.
        if derived
            .task
            .provider_profile
            .as_ref()
            .is_none_or(|profile| profile.protocol != protocol)
        {
            return Err(Status::failed_precondition("source protocol changed"));
        }
        let created_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| Status::internal("gateway clock"))?
            .as_secs();
        let projection = weaver_broker::ProviderSseEncoder::new(
            protocol,
            &derived.plan.model,
            4 * 1024 * 1024,
            created_at,
        )
        .map_err(crate::grpc_contracts::status)?;
        let stream = self.gateway.start_provider_stream(
            slot,
            derived.plan,
            Default::default(),
            None,
            crate::grpc_provider::StreamSettings {
                projection: Some(projection),
                arrow: false,
                batch_rows: 32,
                catalog: String::new(),
            },
        )?;
        let body = StreamBody::new(
            crate::http_delivery::SseStream(stream)
                .map(|result| result.map(hyper::body::Frame::data)),
        );
        let mut response = http::Response::new(Body::new(body));
        response.headers_mut().insert(
            http::header::CONTENT_TYPE,
            http::HeaderValue::from_static("text/event-stream"),
        );
        response.headers_mut().insert(
            http::header::CACHE_CONTROL,
            http::HeaderValue::from_static("no-store"),
        );
        response
            .headers_mut()
            .insert("x-accel-buffering", http::HeaderValue::from_static("no"));
        Ok(response)
    }
}
fn authenticate(headers: &http::HeaderMap, expected: &[u8; 32]) -> Result<(), Status> {
    let bearer = headers.get_all(http::header::AUTHORIZATION).iter().count();
    let api = headers.get_all("x-api-key").iter().count();
    let token = match (bearer, api) {
        (1, 0) => headers
            .get(http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer ")),
        (0, 1) => headers.get("x-api-key").and_then(|v| v.to_str().ok()),
        _ => None,
    }
    .filter(|v| !v.is_empty() && v.len() <= 256)
    .ok_or(Status::unauthenticated("credential required"))?;
    let actual: [u8; 32] = Sha256::digest(token.as_bytes()).into();
    if !bool::from(actual.ct_eq(expected)) {
        return Err(Status::unauthenticated("credential rejected"));
    }
    Ok(())
}
fn operation_id(headers: &http::HeaderMap) -> Result<String, Status> {
    match headers.get_all("idempotency-key").iter().count() {
        0 => {
            let mut bytes = [0; 32];
            ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes)
                .map_err(|_| Status::internal("request identity unavailable"))?;
            Ok(hex::encode(bytes))
        }
        1 => {
            let value = headers
                .get("idempotency-key")
                .and_then(|v| v.to_str().ok())
                .ok_or(Status::invalid_argument("request identity"))?;
            weaver_contracts::identifier(value).map_err(crate::grpc_contracts::status)?;
            Ok(value.into())
        }
        _ => Err(Status::invalid_argument("duplicate request identity")),
    }
}
async fn read_body(mut body: Body, limit: u64) -> Result<String, Status> {
    let limit = usize::try_from(limit.min(weaver_contracts::MAX_BODY_BYTES as u64))
        .map_err(|_| Status::invalid_argument("body bound"))?;
    let mut bytes = Vec::new();
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(|_| Status::invalid_argument("body read"))?;
        if let Ok(data) = frame.into_data() {
            if data.len() > limit.saturating_sub(bytes.len()) {
                return Err(Status::resource_exhausted("body bound"));
            }
            bytes.extend_from_slice(&data);
        } else {
            return Err(Status::invalid_argument("request trailers unsupported"));
        }
    }
    String::from_utf8(bytes).map_err(|_| Status::invalid_argument("body encoding"))
}

#[cfg(test)]
#[path = "../../tests/unit/http_request.rs"]
mod tests;
