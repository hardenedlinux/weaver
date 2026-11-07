// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Read bounded process configuration outside the async I/O executor.
use crate::rpc_security::{GrpcConfig, GrpcListeners, RpcSecurity};
use std::{collections::BTreeMap, io::Read};
use tonic::transport::{Certificate, Identity, ServerTlsConfig};
use weaver_broker::ProviderTransport;
use weaver_contracts::{Error, Result};
fn required(name: &str) -> Result<String> {
    std::env::var(name).map_err(|_| Error::Invalid("required gRPC configuration missing"))
}
fn read_path(path: impl AsRef<std::path::Path>) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .map_err(|_| Error::Invalid("RPC configuration file"))?
        .take(65537)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::Invalid("RPC configuration read"))?;
    if bytes.len() > 65536 {
        return Err(Error::Invalid("RPC configuration bound"));
    }
    Ok(bytes)
}
fn read(name: &str) -> Result<Vec<u8>> {
    read_path(required(name)?)
}
fn digest(name: &str) -> Result<[u8; 32]> {
    hex::decode(required(name)?)
        .map_err(|_| Error::Invalid("gRPC identity digest"))?
        .try_into()
        .map_err(|_| Error::Invalid("gRPC identity digest"))
}
fn load_security() -> Result<RpcSecurity> {
    Ok(RpcSecurity {
        tls: ServerTlsConfig::new()
            .identity(Identity::from_pem(
                read("WEAVER_GRPC_CERT")?,
                read("WEAVER_GRPC_KEY")?,
            ))
            .client_ca_root(Certificate::from_pem(read("WEAVER_GRPC_CLIENT_CA")?)),
        peer_sha256: digest("WEAVER_GRPC_PEER_SHA256")?,
        source_peer_sha256: digest("WEAVER_GRPC_SOURCE_PEER_SHA256")?,
        admin_sha256: digest("WEAVER_ADMIN_TOKEN_SHA256")?,
    })
}
fn load_transport() -> Result<ProviderTransport> {
    let names: BTreeMap<String, String> = match std::env::var("WEAVER_PROVIDER_CREDENTIAL_ENVS") {
        Ok(value) => weaver_contracts::decode(value.as_bytes())?,
        Err(std::env::VarError::NotPresent) => BTreeMap::new(),
        Err(_) => return Err(Error::Invalid("provider credential encoding")),
    };
    let federation = match std::env::var("WEAVER_ANTHROPIC_WIF") {
        Ok(value) => weaver_contracts::decode(value.as_bytes())?,
        Err(std::env::VarError::NotPresent) => BTreeMap::new(),
        Err(_) => return Err(Error::Invalid("WIF configuration encoding")),
    };
    if names.len() > 8 {
        return Err(Error::Invalid("provider configuration bound"));
    }
    let mut credentials = BTreeMap::new();
    for (target, name) in names {
        credentials.insert(target, required(&name)?);
    }
    let root = std::env::var("WEAVER_PROVIDER_CA")
        .ok()
        .map(read_path)
        .transpose()?;
    #[cfg(test)]
    if let Ok(peer) = std::env::var("WEAVER_TEST_WIF_PEER") {
        if !credentials.is_empty() {
            return Err(Error::Invalid("WIF test credentials"));
        }
        return ProviderTransport::with_wif_loopback(
            federation,
            root.as_deref().ok_or(Error::Invalid("WIF test root"))?,
            tokio::runtime::Handle::current(),
            peer.parse()
                .map_err(|_| Error::Invalid("WIF test address"))?,
        );
    }
    ProviderTransport::with_anthropic_wif(
        credentials,
        federation,
        root.as_deref(),
        tokio::runtime::Handle::current(),
    )
}

#[cfg(test)]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "started as a child by the Go WIF fixture"]
async fn serve_wif_gateway() {
    crate::entrypoint::run_on_runtime()
        .await
        .expect("WIF test gateway");
}
struct ListenAddresses {
    operation: std::net::SocketAddr,
    source: std::net::SocketAddr,
}
fn address(name: &str, default: &str) -> Result<std::net::SocketAddr> {
    let address: std::net::SocketAddr = std::env::var(name)
        .unwrap_or_else(|_| default.into())
        .parse()
        .map_err(|_| Error::Invalid("gRPC listen address"))?;
    if !address.ip().is_loopback() {
        return Err(Error::Invalid(
            "current RPC owner profile requires loopback",
        ));
    }
    Ok(address)
}
fn load() -> Result<(GrpcConfig, ListenAddresses)> {
    let owner = crate::config::from_env()?;
    owner.validate()?;
    let addresses = ListenAddresses {
        operation: address("WEAVER_LISTEN", "127.0.0.1:18080")?,
        source: address("WEAVER_SOURCE_LISTEN", "127.0.0.1:18081")?,
    };
    if addresses.operation == addresses.source {
        return Err(Error::Invalid("distinct RPC ingress addresses required"));
    }
    Ok((
        GrpcConfig {
            review_authority: weaver_contracts::decode(
                required("WEAVER_REVIEW_AUTHORITY")?.as_bytes(),
            )?,
            metering: match std::env::var("WEAVER_METERING") {
                Ok(config) => Some(weaver_contracts::decode(config.as_bytes())?),
                Err(std::env::VarError::NotPresent) => None,
                Err(_) => return Err(Error::Invalid("metering deployment encoding")),
            },
            provider_oauth: match std::env::var("WEAVER_PROVIDER_OAUTH") {
                Ok(config) => Some(weaver_contracts::decode(config.as_bytes())?),
                Err(std::env::VarError::NotPresent) => None,
                Err(_) => return Err(Error::Invalid("provider OAuth deployment encoding")),
            },
            owner,
            security: load_security()?,
            provider: load_transport()?,
        },
        addresses,
    ))
}
/// Start the default mTLS RPC service; no command/stdio request protocol exists.
pub async fn run_from_env() -> Result<()> {
    let runtime = crate::ServiceRuntime::new();
    let result = run_owned(runtime.clone()).await;
    runtime.drain().await;
    result
}
async fn run_owned(runtime: crate::ServiceRuntime) -> Result<()> {
    let _lifetime = runtime.shutdown_guard();
    let started = std::time::Instant::now();
    eprintln!(
        "weaver startup stage=runtime-entered clock={:?}",
        std::time::SystemTime::now()
    );
    let shutdown = crate::shutdown::signal()?;
    let (settings, addresses, catalog) = crate::runtime::RuntimeOwner::initialize(|| {
        let (settings, addresses) = load()?;
        Ok((
            settings,
            addresses,
            crate::governance_deployment::load_catalog()?,
        ))
    })
    .await?;
    let worker = crate::governance_deployment::start(&runtime, catalog).await?;
    eprintln!(
        "weaver startup stage=configured elapsed={:?}",
        started.elapsed()
    );
    let (operation, source) = tokio::try_join!(
        tokio::net::TcpListener::bind(addresses.operation),
        tokio::net::TcpListener::bind(addresses.source)
    )
    .map_err(|_| Error::Invalid("gRPC listener"))?;
    eprintln!(
        "weaver startup stage=listeners-bound elapsed={:?}",
        started.elapsed()
    );
    let result = crate::grpc::serve_grpc_with_runtime(
        GrpcListeners { operation, source },
        settings,
        runtime,
        shutdown,
    )
    .await;
    if let Some(worker) = worker {
        worker.finish().await?;
    }
    result
}
