// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{StoredToken, scope_matches};
use proptest::{
    prop_assert, proptest,
    test_runner::{Config as ProptestConfig, RngSeed, TestCaseError},
};

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 64, rng_seed: RngSeed::Fixed(293), ..ProptestConfig::default()
    })]
    #[test]
    fn issuance_and_expiry_boundaries_are_enforced(
        issued in 1u64..1_000_000, lifetime in 31u64..86400, elapsed in 0u64..100_000,
    ) {
        let token = StoredToken { access: "secret".into(), refresh: None,
            issued_at: issued, expires_at: issued+lifetime, scopes: vec!["read".into()], refresh_at: None };
        prop_assert!(!token.fresh(issued-1));
        prop_assert!(!token.fresh(issued+lifetime));
        if token.fresh(issued+elapsed) {
            prop_assert!(elapsed+30 < lifetime);
        }
    }

    #[test]
    fn refresh_hint_can_only_shorten_a_tokens_fresh_window(
        issued in 1u64..1_000_000, lifetime in 31u64..86400,
        hint in 1u64..100_000, elapsed in 0u64..100_000,
    ) {
        let mut token = StoredToken {access:"api-only".into(),refresh:None,issued_at:issued,
            expires_at:issued+lifetime,scopes:vec!["read:user".into()],refresh_at:None};
        let originally_fresh = token.fresh(issued+elapsed);
        token.refresh_at=Some(issued+hint);
        if token.fresh(issued+elapsed) {
            prop_assert!(originally_fresh);
            prop_assert!(elapsed<hint);
        }
        prop_assert!(!token.fresh(issued+hint));
        prop_assert!(!token.fresh(issued+lifetime));
    }

    #[test]
    fn scope_expansion_and_missing_required_scope_are_rejected(
        scopes in proptest::collection::btree_set("[a-z]{1,12}", 1..12),
    ) {
        let required: Vec<String> = scopes.into_iter().collect();
        let mut expanded = required.clone();
        expanded.push("unrequested:admin".into());
        prop_assert!(!scope_matches(&required, &expanded));
        prop_assert!(!scope_matches(&required, &required[1..]));
        let mut reordered = required.clone();
        reordered.reverse();
        prop_assert!(scope_matches(&required, &reordered));
    }

    #[test]
    fn persisted_credentials_reject_header_injection_and_scope_substitution(
        prefix in "[a-zA-Z0-9]{1,64}", suffix in "[a-zA-Z0-9]{1,64}",
        issued in 1u64..1_000_000,
    ) {
        let required = vec!["read".to_owned()];
        let mut token = StoredToken {
            access: prefix.clone(), refresh: None, issued_at: issued,
            expires_at: issued + 3600, scopes: required.clone(), refresh_at: None,
        };
        prop_assert!(token.valid(&required));
        token.access = format!("{prefix}\r\nAuthorization: Bearer {suffix}");
        prop_assert!(!token.valid(&required));
        token.access = prefix;
        token.scopes = vec!["admin".into()];
        prop_assert!(!token.valid(&required));
    }

    #[test]
    fn private_record_roundtrip_preserves_time_and_refresh_boundaries(
        issued in 1u64..1_000_000, lifetime in 31u64..86400,
        hint in 1u64..100_000, elapsed in 0u64..100_000,
    ) {
        let required=vec!["read".to_owned()];
        let original=StoredToken {access:"synthetic-access".into(),refresh:Some("synthetic-refresh".into()),
            issued_at:issued,expires_at:issued+lifetime,scopes:required.clone(),refresh_at:Some(issued+hint)};
        let json=serde_json::to_vec(&original).map_err(|_|TestCaseError::fail("serialize credential"))?;
        let restored:StoredToken=serde_json::from_slice(&json).map_err(|_|TestCaseError::fail("restore credential"))?;
        prop_assert!(restored.valid(&required));
        prop_assert!(restored.fresh(issued+elapsed)==original.fresh(issued+elapsed));
        prop_assert!(!restored.fresh(issued-1));
        prop_assert!(!restored.fresh(issued+lifetime));
        prop_assert!(!restored.fresh(issued+hint));
    }

    #[test]
    fn restored_credential_rejects_nonpositive_lifetime_or_refresh_window(
        issued in 1u64..1_000_000, expired_by in 0u64..1_000_000,
    ) {
        let required=vec!["read".to_owned()];
        let mut record=serde_json::json!({"access":"synthetic-access","refresh":null,
            "issued_at":issued,"expires_at":issued+3600,"scopes":["read"]});
        record["expires_at"]=serde_json::json!(issued.saturating_sub(expired_by));
        let token:StoredToken=serde_json::from_value(record.clone()).map_err(|_|TestCaseError::fail("restore expired credential"))?;
        prop_assert!(!token.valid(&required));
        record["expires_at"]=serde_json::json!(issued+3600);
        record["refresh_at"]=serde_json::json!(issued.saturating_sub(expired_by));
        let token:StoredToken=serde_json::from_value(record).map_err(|_|TestCaseError::fail("restore invalid refresh window"))?;
        prop_assert!(!token.valid(&required));
    }
}
