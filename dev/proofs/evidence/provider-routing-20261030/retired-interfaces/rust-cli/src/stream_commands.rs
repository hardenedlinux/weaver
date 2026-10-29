//! Local-owner stream registration, queue inspection and explicit bounded emission.
use weaver_contracts::{
    Error, MessageState, Result, StreamContract, StreamMessage, WriteObservation,
};
use weaver_execution::{OpenStream, StreamSession};
use weaver_ledger::Ledger;

pub(crate) fn run(ledger: &mut Ledger, command: &str, args: &[String]) -> Result<()> {
    match (command, args) {
        ("stream-register", [file]) => {
            ledger.register_stream(&crate::commands::read_json::<StreamContract>(file)?)
        }
        ("stream-enqueue", [file]) => {
            let p: StreamMessage = crate::commands::read_json(file)?;
            println!("{}", serde_json::to_string(&ledger.enqueue_message(&p)?)?);
            Ok(())
        }
        ("stream-lookup", [family, node, message]) => {
            println!(
                "{}",
                serde_json::to_string(&ledger.message_receipt(family, node, message)?)?
            );
            Ok(())
        }
        ("stream-send", [file, message, revision, fence, range]) => {
            let c: StreamContract = crate::commands::read_json(file)?;
            let revision = revision.parse().map_err(|_| Error::Invalid("revision"))?;
            let fence = fence.parse().map_err(|_| Error::Invalid("fence"))?;
            let range = range.parse().map_err(|_| Error::Invalid("range"))?;
            let mut session = StreamSession::open_tcp(
                ledger,
                OpenStream {
                    family: &c.family,
                    node: &c.node,
                    destination: &c.destination,
                    revision,
                    fence,
                },
            )?;
            // Explicitly reauthorize the original unsent record; no new key or hold.
            session.resume_message(ledger, message, revision, fence)?;
            loop {
                if ledger
                    .message_receipt(&c.family, &c.node, message)?
                    .ok_or(Error::Conflict("message missing"))?
                    .state
                    == MessageState::Complete
                {
                    break;
                }
                if session.send_next(ledger, message, range)? != WriteObservation::Complete {
                    break;
                }
            }
            session.close();
            println!(
                "{}",
                serde_json::to_string(&ledger.message_receipt(&c.family, &c.node, message)?)?
            );
            Ok(())
        }
        _ => Err(Error::Invalid("stream command arguments")),
    }
}
