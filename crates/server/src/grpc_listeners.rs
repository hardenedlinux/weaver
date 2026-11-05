// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Independent ingress identity and deployment validation.
use crate::rpc_security::{GrpcConfig, GrpcListeners};
use std::task::{Context, Poll};
use weaver_contracts::Error;

pub(crate) fn validate_listeners(
    listeners: &GrpcListeners,
    settings: &GrpcConfig,
) -> weaver_contracts::Result<()> {
    settings.owner.validate()?;
    settings.review_authority.validate()?;
    if let Some(oauth) = &settings.provider_oauth {
        oauth.validate()?;
        if oauth.subject != settings.owner.principal
            || oauth
                .relay_certificate_sha256
                .as_ref()
                .is_some_and(|relay| relay != &hex::encode(settings.security.peer_sha256))
            || oauth.public_key == settings.review_authority.public_key
            || settings.metering.as_ref().is_some_and(|metering| {
                metering
                    .tenants
                    .values()
                    .any(|tenant| tenant.public_key == oauth.public_key)
            })
        {
            return Err(Error::Invalid(
                "provider OAuth principal or issuer separation",
            ));
        }
    }
    if let Some(metering) = &settings.metering {
        metering.validate()?;
        if metering
            .tenants
            .values()
            .any(|tenant| tenant.public_key == settings.review_authority.public_key)
        {
            return Err(Error::Invalid(
                "metering and review keys must be independent",
            ));
        }
    }
    let operation = listeners
        .operation
        .local_addr()
        .map_err(|e| Error::Storage(e.to_string()))?;
    let source = listeners
        .source
        .local_addr()
        .map_err(|e| Error::Storage(e.to_string()))?;
    if settings.security.admin_sha256 == [0; 32]
        || settings.security.peer_sha256 == [0; 32]
        || settings.security.source_peer_sha256 == [0; 32]
        || settings.security.source_peer_sha256 == settings.security.peer_sha256
        || settings.security.admin_sha256 == settings.owner.token_sha256
        || !operation.ip().is_loopback()
        || !source.ip().is_loopback()
        || operation == source
    {
        return Err(Error::Invalid("RPC identity or loopback profile"));
    }
    Ok(())
}
// Tonic interceptors cannot see the HTTP path. Classify the exact wire
// methods before the interceptor strips it, using a server-local extension.
#[derive(Clone)]
pub(crate) struct MeterPaths<S>(pub(crate) S);

#[derive(Clone)]
pub(crate) struct MeterMethod;

impl<S: tonic::server::NamedService> tonic::server::NamedService for MeterPaths<S> {
    const NAME: &'static str = S::NAME;
}

impl<S, B> tonic::codegen::Service<tonic::codegen::http::Request<B>> for MeterPaths<S>
where
    S: tonic::codegen::Service<tonic::codegen::http::Request<B>>,
{
    type Response = S::Response;
    type Error = S::Error;
    type Future = S::Future;

    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<std::result::Result<(), Self::Error>> {
        self.0.poll_ready(cx)
    }

    fn call(&mut self, mut request: tonic::codegen::http::Request<B>) -> Self::Future {
        if matches!(
            request.uri().path(),
            "/weaver.gateway.v1.Gateway/InspectTerminalUsage"
                | "/weaver.gateway.v1.Gateway/ApplyMetering"
        ) {
            request.extensions_mut().insert(MeterMethod);
        }
        self.0.call(request)
    }
}
