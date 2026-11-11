// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Operation-only client: TLS/bearer custody remains separate from delegated exchange.

use crate::{pb, source_prepare::Bearer};
use std::time::Duration;
use tonic::{
    Request, Response, Status, Streaming,
    metadata::{Ascii, MetadataValue},
    service::interceptor::InterceptedService,
    transport::{Certificate, Channel, ClientTlsConfig, Endpoint, Identity},
};
use weaver_llm::{Configuration, PreparedOperation, oauth::OAuthSession};

/// Clones share a connection and credential owner. No publication RPC is exposed.
#[derive(Clone)]
pub struct OperationClient {
    client: pb::gateway_client::GatewayClient<InterceptedService<Channel, Bearer>>,
    identity: OAuthSession,
    resource: String,
    operation: MetadataValue<Ascii>,
}

impl OperationClient {
    /// Prepare one named `weaver.toml` profile and connect its mTLS operation lane.
    ///
    /// # Errors
    /// Rejects configuration, TLS and connection failures with redacted status.
    pub async fn from_config(
        config: &Configuration,
        name: &str,
        timeout: Duration,
    ) -> Result<Self, Status> {
        let prepared = config
            .prepare_operation(name)
            .await
            .map_err(|_| Status::invalid_argument("operation profile rejected"))?;
        Self::connect(prepared, timeout).await
    }

    /// Connect immutable prepared transport material on the caller's Tokio runtime.
    ///
    /// # Errors
    /// Rejects insecure endpoints, invalid TLS material or unavailable peers.
    pub async fn connect(prepared: PreparedOperation, timeout: Duration) -> Result<Self, Status> {
        if !prepared.endpoint.starts_with("https://") || timeout.is_zero() {
            return Err(Status::invalid_argument("operation TLS endpoint required"));
        }
        let _ = rustls::crypto::ring::default_provider().install_default();
        let operation = metadata(
            prepared
                .operation_bearer
                .to_str()
                .map_err(|_| Status::invalid_argument("operation credential"))?,
        )?;
        let tls = ClientTlsConfig::new()
            .domain_name(prepared.server_name)
            .ca_certificate(Certificate::from_pem(prepared.ca.as_slice()))
            .identity(Identity::from_pem(
                prepared.certificate.as_slice(),
                prepared.key.as_slice(),
            ));
        let channel = Endpoint::from_shared(prepared.endpoint.clone())
            .and_then(|endpoint| {
                endpoint
                    .timeout(timeout)
                    .connect_timeout(timeout)
                    .tls_config(tls)
            })
            .map_err(|_| Status::invalid_argument("operation TLS configuration"))?
            .connect()
            .await
            .map_err(|_| Status::unavailable("operation listener unavailable"))?;
        Ok(Self {
            client: pb::gateway_client::GatewayClient::with_interceptor(
                channel,
                Bearer::new(operation.clone()),
            ),
            identity: prepared.identity,
            resource: prepared.endpoint,
            operation,
        })
    }

    /// Shared browser-login, logout and refresh owner; no source authority.
    pub fn identity(&self) -> &OAuthSession {
        &self.identity
    }

    /// Execute once through the existing provider RPC and final release guards.
    ///
    /// # Errors
    /// Returns credential, admission and provider errors without automatic replay.
    pub async fn execute(
        &mut self,
        request: pb::ProviderRequest,
    ) -> Result<Response<Streaming<pb::ProviderFrame>>, Status> {
        let credential = self
            .identity
            .delegated_credential(&self.resource)
            .await
            .map_err(|_| Status::unauthenticated("delegated acquisition failed"))?;
        let header = credential
            .bearer_header()
            .map_err(|_| Status::unauthenticated("delegated credential"))?;
        let delegated = metadata(
            header
                .to_str()
                .map_err(|_| Status::unauthenticated("delegated credential"))?,
        )?;
        if delegated == self.operation {
            return Err(Status::unauthenticated(
                "operation and delegated credentials must differ",
            ));
        }
        let mut request = Request::new(request);
        request
            .metadata_mut()
            .insert("weaver-provider-oauth", delegated);
        self.client.execute_provider(request).await
    }
}

fn metadata(value: &str) -> Result<MetadataValue<Ascii>, Status> {
    let mut value: MetadataValue<Ascii> = value
        .parse()
        .map_err(|_| Status::unauthenticated("operation credential encoding"))?;
    value.set_sensitive(true);
    Ok(value)
}
