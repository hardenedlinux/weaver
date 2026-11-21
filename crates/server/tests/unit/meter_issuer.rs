// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{require_binding, sign};
use crate::pb;
use proptest::{
    prelude::{TestCaseError, any},
    prop_assert, prop_assert_eq, prop_assert_ne, proptest,
};
use ring::signature::Ed25519KeyPair;

proptest! {
    #[test]
    fn meter_signs_only_the_bound_original(
        family in "[a-z][a-z0-9]{0,12}",
        node in "[a-z][a-z0-9]{0,12}",
        tokens in any::<[u16; 4]>(),
        seed in any::<[u8; 32]>(),
        changed_coordinate in 0_u8..8,
    ) {
        let key = pb::OperationKey { family, node };
        let terminal = "a".repeat(64);
        let mut wire = pb::MeteringReceipt {
            audience: "audience".into(),
            tenant: "tenant".into(),
            issuer: "issuer".into(),
            application: terminal.clone(),
            family: key.family.clone(),
            node: key.node.clone(),
            origin: "origin".into(),
            plan_digest: "b".repeat(64),
            target: "target".into(),
            formula_digest: "c".repeat(64),
            terminal_digest: terminal,
            tokens: tokens.into_iter().map(u64::from).collect(),
            signature: String::new(),
        };
        prop_assert!(require_binding(&wire, &key, "audience", "tenant", "issuer").is_ok());
        let signer = Ed25519KeyPair::from_seed_unchecked(&seed)
            .map_err(|_| TestCaseError::fail("Ed25519 seed rejected"))?;
        let original = sign(&wire, &signer).map_err(|error| TestCaseError::fail(error.to_string()))?;
        let restarted = Ed25519KeyPair::from_seed_unchecked(&seed)
            .map_err(|_| TestCaseError::fail("Ed25519 seed rejected on restart"))?;
        let replay = sign(&wire, &restarted).map_err(|error| TestCaseError::fail(error.to_string()))?;
        prop_assert_eq!(&replay, &original);
        wire.tokens[0] += 1;
        let changed = sign(&wire, &restarted).map_err(|error| TestCaseError::fail(error.to_string()))?;
        prop_assert_ne!(&changed, &original);

        match changed_coordinate {
            0 => wire.audience.push('x'),
            1 => wire.tenant.push('x'),
            2 => wire.issuer.push('x'),
            3 => wire.family.push('x'),
            4 => wire.node.push('x'),
            5 => wire.application = "d".repeat(64),
            6 => wire.terminal_digest = "e".repeat(64),
            _ => wire.signature = original,
        }
        prop_assert!(require_binding(&wire, &key, "audience", "tenant", "issuer").is_err());
    }
}
