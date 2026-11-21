// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Independent terminal usage signing over the authenticated source RPC.

use crate::{grpc_config::required, pb, source_prepare::connect_meter};
use ring::signature::Ed25519KeyPair;
use std::time::Duration;
use tokio::{fs::File, io::AsyncReadExt};
use weaver_contracts::{Error, MeteringApplication, MeteringReceipt, Result};
use zeroize::Zeroizing;

pub(crate) async fn settle(
    family: String,
    node: String,
    timeout: Duration,
) -> Result<MeteringApplication> {
    let key = pb::OperationKey { family, node };
    let audience = required("WEAVER_METER_AUDIENCE")?;
    let tenant = required("WEAVER_METER_TENANT")?;
    let issuer = required("WEAVER_METER_ISSUER")?;
    for identity in [&key.family, &key.node, &audience, &tenant, &issuer] {
        weaver_contracts::identifier(identity)?;
    }
    let signing_key = load_signing_key().await?;
    let mut client = connect_meter(timeout).await?;
    let mut wire = client
        .inspect_terminal_usage(key.clone())
        .await
        .map_err(|_| Error::Conflict("terminal usage observation unavailable"))?
        .into_inner();
    require_binding(&wire, &key, &audience, &tenant, &issuer)?;
    wire.signature = sign(&wire, &signing_key)?;
    let application = wire.application.clone();
    let result = client
        .apply_metering(wire)
        .await
        .map_err(|_| Error::Conflict("metering application result unknown"))?
        .into_inner();
    if result.application != application {
        return Err(Error::Conflict("unexpected metering application binding"));
    }
    Ok(MeteringApplication {
        application,
        charged: result.charged,
        released: result.released,
    })
}

fn require_binding(
    wire: &pb::MeteringReceipt,
    key: &pb::OperationKey,
    audience: &str,
    tenant: &str,
    issuer: &str,
) -> Result<()> {
    if wire.audience != audience
        || wire.tenant != tenant
        || wire.issuer != issuer
        || wire.family != key.family
        || wire.node != key.node
        || wire.application != wire.terminal_digest
        || !wire.signature.is_empty()
    {
        return Err(Error::Invalid("unexpected terminal usage binding"));
    }
    Ok(())
}

async fn load_signing_key() -> Result<Ed25519KeyPair> {
    let path = required("WEAVER_METER_SIGNING_SEED")?;
    let mut text = Zeroizing::new(String::new());
    File::open(path)
        .await
        .map_err(|_| Error::Invalid("meter signing seed file"))?
        .take(130)
        .read_to_string(&mut text)
        .await
        .map_err(|_| Error::Invalid("meter signing seed file"))?;
    let mut seed = Zeroizing::new([0_u8; 32]);
    if text.len() > 129 || hex::decode_to_slice(text.trim(), seed.as_mut()).is_err() {
        return Err(Error::Invalid("invalid meter signing seed"));
    }
    Ed25519KeyPair::from_seed_unchecked(seed.as_ref())
        .map_err(|_| Error::Invalid("invalid meter signing seed"))
}

fn sign(wire: &pb::MeteringReceipt, key: &Ed25519KeyPair) -> Result<String> {
    let receipt = MeteringReceipt {
        audience: wire.audience.clone(),
        tenant: wire.tenant.clone(),
        issuer: wire.issuer.clone(),
        application: wire.application.clone(),
        family: wire.family.clone(),
        node: wire.node.clone(),
        origin: wire.origin.clone(),
        plan_digest: wire.plan_digest.clone(),
        target: wire.target.clone(),
        formula_digest: wire.formula_digest.clone(),
        terminal_digest: wire.terminal_digest.clone(),
        tokens: wire
            .tokens
            .as_slice()
            .try_into()
            .map_err(|_| Error::Invalid("metering token categories"))?,
        signature: String::new(),
    };
    let mut digest = [0_u8; 32];
    hex::decode_to_slice(receipt.signing_digest()?, &mut digest)
        .map_err(|_| Error::Invalid("metering signing digest"))?;
    Ok(hex::encode(key.sign(&digest).as_ref()))
}

#[cfg(test)]
#[path = "../tests/unit/meter_issuer.rs"]
mod tests;
