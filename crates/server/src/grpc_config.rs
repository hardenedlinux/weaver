//! Read bounded process configuration outside the async I/O executor.
use crate::rpc_security::{GrpcConfig, GrpcListeners, RpcSecurity};
use std::{collections::BTreeMap, io::Read};
use tonic::transport::{Certificate, Identity, ServerTlsConfig};
use weaver_contracts::{Error, Result};
use weaver_execution::ProviderTransport;
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
    let names: BTreeMap<String, String> =
        weaver_contracts::decode(required("WEAVER_PROVIDER_CREDENTIAL_ENVS")?.as_bytes())?;
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
    ProviderTransport::new(credentials, root.as_deref())
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
            owner,
            security: load_security()?,
            provider: load_transport()?,
        },
        addresses,
    ))
}
/// Start the default mTLS RPC service; no command/stdio request protocol exists.
pub async fn run_from_env() -> Result<()> {
    let started = std::time::Instant::now();
    eprintln!(
        "weaver startup stage=runtime-entered clock={:?}",
        std::time::SystemTime::now()
    );
    let shutdown = crate::shutdown::signal()?;
    let (settings, addresses) = crate::runtime::RuntimeOwner::initialize(load).await?;
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
    crate::grpc::serve_grpc(GrpcListeners { operation, source }, settings, shutdown).await
}
