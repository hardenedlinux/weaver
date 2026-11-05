// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Join durable consumption with a single final HTTPS call.
use weaver_contracts::{Receipt, Result};
use weaver_ledger::Ledger;

/// Consume durably and invoke the sole transport owner once.
pub fn execute(
    ledger: &mut Ledger,
    family: &str,
    node: &str,
    transport: &crate::HttpsTransport,
) -> Result<(Receipt, crate::SendObservation)> {
    let permit = ledger.consume(family, node)?;
    let observation = ledger.dispatch(permit, |p| transport.send(p))?;
    let receipt = ledger
        .lookup(family, node)?
        .ok_or(weaver_contracts::Error::Conflict(
            "consumed outcome missing",
        ))?;
    Ok((receipt, observation))
}
