// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Distinct Cedar actions for message admission, recovery and final range writes.
use weaver_contracts::{Error, MessageBinding, Result, StreamContract, Task};

/// Actual deciding-state projection; no request-supplied scope is accepted.
pub struct StreamCheck<'a> {
    pub contract: &'a StreamContract,
    pub message: &'a MessageBinding,
    pub action: &'static str,
    pub offset: u64,
    pub length: u64,
    pub revision: u64,
    pub fence: u64,
}

/// Require error-free Cedar permission for this exact logical message or byte range.
pub fn authorize_stream(source: &str, task: &Task, check: StreamCheck<'_>) -> Result<()> {
    let c = check.contract;
    let m = check.message;
    if !c.matches(task)
        || m.family != c.family
        || m.node != c.node
        || m.contract_digest != c.digest()?
    {
        return Err(Error::Denied);
    }
    crate::authorize::evaluate(
        source,
        &task.principal,
        &c.target,
        check.action,
        serde_json::json!({
            "family":c.family,"node":c.node,"profile":c.profile,"input_digest":c.input_digest,
            "destination":c.destination,"message":m.message,"message_digest":m.digest()?,
            "payload_digest":m.payload_digest,"payload_length":m.payload_length,"ceiling":m.ceiling,"offset":check.offset,"length":check.length,
            "revision":check.revision,"fence":check.fence
        }),
    )
}
