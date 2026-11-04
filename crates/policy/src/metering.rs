// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use weaver_contracts::{Error, Result};

/// Verify deployment-owned metering evidence independently of Policy review.
pub fn verify_metering(
    deployment: &weaver_contracts::MeteringDeployment,
    receipt: &weaver_contracts::MeteringReceipt,
) -> Result<u64> {
    receipt.validate()?;
    let rule = deployment
        .tenants
        .get(&receipt.tenant)
        .ok_or(Error::Denied)?;
    if deployment.audience != receipt.audience
        || rule.issuer != receipt.issuer
        || rule.formula_digest()? != receipt.formula_digest
    {
        return Err(Error::Denied);
    }
    crate::delta_review::verify_signature(
        &rule.public_key,
        &receipt.signing_digest()?,
        &receipt.signature,
    )?;
    rule.charge(receipt.tokens)
}
