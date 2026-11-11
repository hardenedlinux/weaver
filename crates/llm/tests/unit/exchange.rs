// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{ACCESS_TOKEN, ExchangeSettings, Response, validate_response};
use proptest::{
    prop_assert, prop_assert_eq, proptest,
    test_runner::{Config, RngSeed, TestCaseError},
};
use serde_json::json;

fn settings(actor: u64) -> ExchangeSettings {
    ExchangeSettings {
        token_url: "https://issuer.invalid/exchange".into(),
        client_id: "client".into(),
        resource: "https://gateway.invalid/".into(),
        audience: "weaver".into(),
        scopes: vec!["provider:execute".into()],
        client_secret_sha256: None,
        actor_sha256: None,
        actor_type: None,
        actor_expires_at: Some(actor),
        operation_sha256: None,
    }
}

fn response(lifetime: u64, scope: &str, kind: &str) -> Result<Response, TestCaseError> {
    serde_json::from_value(
        json!({"access_token":"synthetic-child-for-tests","token_type":"Bearer",
        "issued_token_type":kind,"expires_in":lifetime,"scope":scope}),
    )
    .map_err(|_| TestCaseError::fail("synthetic exchange response"))
}

proptest! {
    #![proptest_config(Config {cases:64,rng_seed:RngSeed::Fixed(293),..Config::default()})]
    #[test]
    fn child_lifetime_never_exceeds_issuer_parent_or_actor(
        started in 1u64..1_000_000,issued in 31u64..86400,parent in 31u64..86400,actor in 31u64..86400,
    ) {
        let config=settings(started+actor);
        let result=validate_response(response(issued,"provider:execute",ACCESS_TOKEN)?,&config,started,started+parent,started);
        prop_assert!(result.is_ok());
        let token=result.map_err(|_|TestCaseError::fail("valid capped token"))?;
        prop_assert_eq!(token.expires_at,started+issued.min(parent).min(actor));
        prop_assert!(!token.fresh(token.expires_at));
        prop_assert!(validate_response(response(issued,"provider:execute",ACCESS_TOKEN)?,&config,started,started+parent,token.expires_at).is_err());
    }

    #[test]
    fn exchanged_scope_cannot_expand_or_change_issued_token_kind(suffix in "[a-z]{1,24}") {
        let config=settings(10000);
        prop_assert!(validate_response(response(3600,"provider:execute",ACCESS_TOKEN)?,&config,1,10000,1).is_ok());
        let expanded=format!("provider:execute extra:{suffix}");
        prop_assert!(validate_response(response(3600,&expanded,ACCESS_TOKEN)?,&config,1,10000,1).is_err());
        prop_assert!(validate_response(response(3600,"provider:execute","urn:ietf:params:oauth:token-type:id_token")?,&config,1,10000,1).is_err());
    }
}
