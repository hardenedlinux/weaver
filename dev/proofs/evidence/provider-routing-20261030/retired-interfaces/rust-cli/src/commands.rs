//! Trusted local management and adapter commands.
use std::{
    collections::BTreeMap,
    io::{self, Read},
    path::Path,
};
use weaver_contracts::{Error, MAX_BODY_BYTES, Proposal, Result, Task};
use weaver_ledger::Ledger;

pub(crate) fn read_json<T: serde::de::DeserializeOwned>(path: &str) -> Result<T> {
    let bytes = std::fs::read(path).map_err(|e| Error::Storage(e.to_string()))?;
    if bytes.len() > MAX_BODY_BYTES * 2 {
        return Err(Error::Invalid("input size"));
    }
    weaver_contracts::decode(&bytes)
}
/// Execute one trusted local management or adapter command.
pub fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [db, command, rest @ ..] = args.as_slice() else {
        return Err(Error::Invalid(
            "usage: weaver-cli DB publish|register|enqueue|lookup|execute|adapter",
        ));
    };
    let mut ledger = Ledger::open(Path::new(db))?;
    dispatch(&mut ledger, command, rest)
}
fn dispatch(ledger: &mut Ledger, command: &str, rest: &[String]) -> Result<()> {
    if command.starts_with("stream-") {
        return crate::stream_commands::run(ledger, command, rest);
    }
    match (command, rest) {
        ("publish-typed", [policy, schema, expected, fence]) => {
            let source =
                std::fs::read_to_string(policy).map_err(|e| Error::Storage(e.to_string()))?;
            let schema =
                std::fs::read_to_string(schema).map_err(|e| Error::Storage(e.to_string()))?;
            weaver_policy::validate_typed(&source, &schema)?;
            let expected = if expected == "new" {
                None
            } else {
                Some(expected.parse().map_err(|_| Error::Invalid("revision"))?)
            };
            println!(
                "{}",
                ledger.publish(
                    expected,
                    &source,
                    fence.parse().map_err(|_| Error::Invalid("fence"))?
                )?
            );
        }
        ("publish", [policy, expected, fence]) => {
            let source =
                std::fs::read_to_string(policy).map_err(|e| Error::Storage(e.to_string()))?;
            let revision = if expected == "new" {
                None
            } else {
                Some(expected.parse().map_err(|_| Error::Invalid("revision"))?)
            };
            println!(
                "{}",
                ledger.publish(
                    revision,
                    &source,
                    fence.parse().map_err(|_| Error::Invalid("fence"))?
                )?
            );
        }
        ("register", [path]) => {
            let task: Task = read_json(path)?;
            for endpoint in task.endpoints.values() {
                weaver_execution::HttpsTransport::validate_endpoint(endpoint)?;
            }
            ledger.register_task(&task)?;
        }
        ("enqueue", [path]) => {
            let p: Proposal = read_json(path)?;
            println!("{}", serde_json::to_string(&ledger.enqueue(&p)?)?);
        }
        ("adapter", []) => {
            let mut bytes = Vec::new();
            io::stdin()
                .take((MAX_BODY_BYTES * 2 + 1) as u64)
                .read_to_end(&mut bytes)
                .map_err(|e| Error::Storage(e.to_string()))?;
            if bytes.len() > MAX_BODY_BYTES * 2 {
                return Err(Error::Invalid("adapter input size"));
            }
            let p: Proposal = weaver_contracts::decode(&bytes)?;
            println!("{}", serde_json::to_string(&ledger.enqueue(&p)?)?);
        }
        ("lookup", [family, node]) => {
            println!("{}", serde_json::to_string(&ledger.lookup(family, node)?)?)
        }
        ("held", [family]) => println!("{}", ledger.held(family)?),
        ("execute", [family, node]) => {
            let transport = weaver_execution::HttpsTransport::new(BTreeMap::new())?;
            let (receipt, observation) =
                weaver_execution::execute(ledger, family, node, &transport)?;
            println!("{}", serde_json::to_string(&receipt)?);
            eprintln!("{observation:?}");
        }
        _ => return Err(Error::Invalid("command arguments")),
    }
    Ok(())
}
