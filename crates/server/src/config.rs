//! Explicit local service identity and bounded admission configuration.
use std::path::PathBuf;
use weaver_contracts::{Error, Result, identifier};

/// Local owner service configuration; no anonymous or default credential exists.
#[derive(Clone)]
pub struct ServerConfig {
    pub database: PathBuf,
    pub principal: String,
    pub token_sha256: [u8; 32],
    pub max_in_flight: usize,
}
impl ServerConfig {
    pub(crate) fn validate(&self) -> Result<()> {
        identifier(&self.principal)?;
        if self.max_in_flight == 0 || self.max_in_flight > 32 || self.token_sha256 == [0; 32] {
            return Err(Error::Invalid("server identity or concurrency bounds"));
        }
        Ok(())
    }
}
pub(crate) fn from_env() -> Result<ServerConfig> {
    let get = |name| {
        std::env::var(name).map_err(|_| Error::Invalid("required server environment missing"))
    };
    let token_sha256 = hex::decode(get("WEAVER_TOKEN_SHA256")?)
        .map_err(|_| Error::Invalid("token digest"))?
        .try_into()
        .map_err(|_| Error::Invalid("token digest"))?;
    Ok(ServerConfig {
        database: PathBuf::from(get("WEAVER_DB")?),
        principal: get("WEAVER_PRINCIPAL")?,
        token_sha256,
        max_in_flight: 16,
    })
}
