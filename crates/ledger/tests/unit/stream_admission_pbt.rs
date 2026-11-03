// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Model-based admission properties. Proptest owns generation and shrinking;
//! model transitions never depend on whether the real ledger accepted a command.
use super::stream_properties::{fixture, message};
use proptest::{
    collection, prop_assert, prop_assert_eq, prop_oneof, proptest,
    strategy::{Just, Strategy},
    test_runner::TestCaseResult,
};
use std::{collections::BTreeSet, path::PathBuf};
use weaver_contracts::{MessageState, StreamContract};
use weaver_ledger::Ledger;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum MessageKey {
    First,
    Second,
}
impl MessageKey {
    const ALL: [Self; 2] = [Self::First, Self::Second];
    fn id(self) -> u8 {
        match self {
            Self::First => 0,
            Self::Second => 1,
        }
    }
}

#[derive(Clone, Debug)]
enum Command {
    Admit(MessageKey),
    Observe(MessageKey),
    ReplaceAfterClaim(MessageKey),
    Unlisted(u8),
    Restart,
}

fn key_strategy() -> impl Strategy<Value = MessageKey> {
    prop_oneof![Just(MessageKey::First), Just(MessageKey::Second)]
}
fn command_strategy() -> impl Strategy<Value = Command> {
    prop_oneof![
        key_strategy().prop_map(Command::Admit),
        key_strategy().prop_map(Command::Observe),
        key_strategy().prop_map(Command::ReplaceAfterClaim),
        (2u8..5).prop_map(Command::Unlisted),
        Just(Command::Restart),
    ]
}
fn trace_strategy() -> impl Strategy<Value = Vec<Command>> {
    (key_strategy(), collection::vec(command_strategy(), 1..32)).prop_map(|(first, tail)| {
        // Every generated/shrunk trace exercises at least one admissible command.
        std::iter::once(Command::Admit(first)).chain(tail).collect()
    })
}

#[derive(Default)]
struct Model {
    claims: BTreeSet<MessageKey>,
}
impl Model {
    fn advance(&mut self, command: &Command) {
        match command {
            Command::Admit(key) | Command::ReplaceAfterClaim(key) => {
                self.claims.insert(*key);
            }
            Command::Observe(_) | Command::Unlisted(_) | Command::Restart => {}
        }
    }
    fn held(&self) -> u64 {
        4 * self.claims.len() as u64
    }
}

struct Driver {
    path: PathBuf,
    ledger: Option<Ledger>,
    contract: StreamContract,
}
impl Driver {
    fn apply(&mut self, command: &Command) -> TestCaseResult {
        if matches!(command, Command::Restart) {
            drop(self.ledger.take());
            self.ledger = Some(Ledger::open(&self.path).expect("durable restart"));
            return Ok(());
        }
        let ledger = self.ledger.as_mut().expect("live driver");
        match command {
            Command::Admit(key) => {
                let result = ledger.enqueue_message(&message(&self.contract, key.id(), 0, 1));
                prop_assert!(
                    result.is_ok(),
                    "admissible original/replay rejected: {result:?}"
                );
            }
            Command::ReplaceAfterClaim(key) => {
                let original = message(&self.contract, key.id(), 0, 1);
                prop_assert!(ledger.enqueue_message(&original).is_ok());
                let mut forged = original;
                forged.payload = "replaced".into();
                prop_assert!(ledger.enqueue_message(&forged).is_err());
            }
            Command::Unlisted(id) => {
                prop_assert!(
                    ledger
                        .enqueue_message(&message(&self.contract, *id, 0, 1))
                        .is_err()
                );
            }
            Command::Observe(key) => {
                let _ = ledger
                    .message_receipt("f", "emit", &format!("m{}", key.id()))
                    .expect("observe");
            }
            Command::Restart => unreachable!(),
        }
        Ok(())
    }
    fn check(&self, model: &Model) -> TestCaseResult {
        let ledger = self.ledger.as_ref().expect("live driver");
        prop_assert_eq!(ledger.held("f").expect("held"), model.held());
        prop_assert!(model.held() <= 8);
        for key in MessageKey::ALL {
            let observed = ledger
                .message_receipt("f", "emit", &format!("m{}", key.id()))
                .expect("receipt");
            prop_assert_eq!(observed.is_some(), model.claims.contains(&key));
            if let Some(receipt) = observed {
                prop_assert_eq!(
                    receipt.digest,
                    message(&self.contract, key.id(), 0, 1)
                        .digest()
                        .expect("identity")
                );
                prop_assert_eq!(receipt.reserved, 4);
                prop_assert_eq!(receipt.cursor, 0);
                prop_assert_eq!(receipt.state, MessageState::Queued);
            }
        }
        for id in 2..5 {
            prop_assert!(
                ledger
                    .message_receipt("f", "emit", &format!("m{id}"))
                    .expect("unlisted receipt")
                    .is_none(),
                "unlisted message acquired a claim"
            );
        }
        Ok(())
    }
}

proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(64))]
    #[test]
    fn approved_command_prefixes_refine_independent_admission_model(commands in trace_strategy()) {
        let temp=tempfile::tempdir().expect("store");
        let path=temp.path().join("admission.db");
        let (ledger,contract)=fixture(&path);
        let mut driver=Driver{path,ledger:Some(ledger),contract};
        let mut model=Model::default();
        driver.check(&model)?;
        for command in commands {
            model.advance(&command);
            driver.apply(&command)?;
            driver.check(&model)?;
        }
    }
}
