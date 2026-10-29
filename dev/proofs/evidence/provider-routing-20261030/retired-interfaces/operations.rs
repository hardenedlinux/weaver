//! Identity-scoped local service operations; no request can provision original task authority.
use crate::ServerConfig;
use serde::Deserialize;
use weaver_contracts::{
    Error, MAX_BODY_BYTES, MessageReceipt, MessageState, Result, StreamMessage, WriteObservation,
};
use weaver_execution::{OpenStream, StreamSession};
use weaver_ledger::Ledger;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SendRequest {
    pub revision: u64,
    pub fence: u64,
    pub max_range: usize,
}

pub(crate) fn enqueue(config: &ServerConfig, message: StreamMessage) -> Result<MessageReceipt> {
    let mut ledger = Ledger::open(&config.database)?;
    ledger.require_principal(&config.principal, &message.family)?;
    ledger.enqueue_message(&message)
}
pub(crate) fn lookup(
    config: &ServerConfig,
    key: (String, String, String),
) -> Result<Option<MessageReceipt>> {
    let ledger = Ledger::open(&config.database)?;
    ledger.require_principal(&config.principal, &key.0)?;
    ledger.message_receipt(&key.0, &key.1, &key.2)
}
pub(crate) fn send(
    config: &ServerConfig,
    key: (String, String, String),
    request: SendRequest,
    cancel: tokio_util::sync::CancellationToken,
) -> Result<MessageReceipt> {
    if cancel.is_cancelled() {
        return Err(Error::Conflict("runtime cancelled before send"));
    }
    if request.max_range == 0 || request.max_range > MAX_BODY_BYTES {
        return Err(Error::Invalid("range bound"));
    }
    let mut ledger = Ledger::open(&config.database)?;
    ledger.require_principal(&config.principal, &key.0)?;
    let receipt = ledger
        .message_receipt(&key.0, &key.1, &key.2)?
        .ok_or(Error::Conflict("message missing"))?;
    if receipt.state == MessageState::Complete {
        return Ok(receipt);
    }
    let contract = ledger.stream_contract(&key.0, &key.1)?;
    if cancel.is_cancelled() {
        return Err(Error::Conflict("runtime cancelled before connection"));
    }
    // This local service profile exposes only the loopback sink. TLS is provided by execution's trusted API.
    let mut session = StreamSession::open_tcp(
        &mut ledger,
        OpenStream {
            family: &key.0,
            node: &key.1,
            destination: &contract.destination,
            revision: request.revision,
            fence: request.fence,
        },
    )?;
    session.resume_message(&mut ledger, &key.2, request.revision, request.fence)?;
    emit(&mut ledger, &mut session, &key, request.max_range, &cancel)?;
    ledger
        .message_receipt(&key.0, &key.1, &key.2)?
        .ok_or(Error::Conflict("outcome missing"))
}
fn emit(
    ledger: &mut Ledger,
    session: &mut StreamSession,
    key: &(String, String, String),
    limit: usize,
    cancel: &tokio_util::sync::CancellationToken,
) -> Result<()> {
    loop {
        if cancel.is_cancelled() {
            session.close();
            return Err(Error::Conflict("runtime shutdown between ranges"));
        }
        if ledger
            .message_receipt(&key.0, &key.1, &key.2)?
            .ok_or(Error::Conflict("message missing"))?
            .state
            == MessageState::Complete
        {
            break;
        }
        if session.send_next(ledger, &key.2, limit)? != WriteObservation::Complete {
            break;
        }
    }
    session.close();
    Ok(())
}
