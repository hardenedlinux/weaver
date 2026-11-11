// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Audience, Claims, Registration, registered_account, validate_identity};
use proptest::{
    prop_assert, proptest,
    test_runner::{Config as ProptestConfig, RngSeed},
};

fn registration() -> Registration {
    Registration {
        client_id: Some("oaiapp-selected".into()),
        subject: Some("selected-subject".into()),
        email: Some("same@example.invalid".into()),
        id_token: None,
        nonce: Some("original-nonce".into()),
        host_id: "host".into(),
    }
}

fn claims() -> Claims {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|v| v.as_secs())
        .unwrap_or(0);
    Claims {
        sub: "selected-subject".into(),
        exp: now + 3600,
        iat: now,
        nonce: Some("original-nonce".into()),
        email: Some("same@example.invalid".into()),
        aud: Audience::One("oaiapp-selected".into()),
        azp: None,
    }
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 64, rng_seed: RngSeed::Fixed(293), ..ProptestConfig::default()
    })]
    #[test]
    fn signed_account_identity_cannot_be_replaced_by_another_subject(suffix in "[a-z]{1,24}") {
        let saved = registration();
        let mut value = claims();
        prop_assert!(validate_identity(&value, &saved, Some("original-nonce")).is_ok());
        value.sub = format!("another-subject-{suffix}");
        prop_assert!(validate_identity(&value, &saved, Some("original-nonce")).is_err());
    }

    #[test]
    fn nonce_and_authorized_party_substitution_are_rejected(suffix in "[a-z]{1,24}") {
        let saved = registration();
        let mut value = claims();
        value.nonce = Some(format!("other-nonce-{suffix}"));
        prop_assert!(validate_identity(&value, &saved, Some("original-nonce")).is_err());
        value.nonce = Some("original-nonce".into());
        value.aud = Audience::Many(vec!["oaiapp-selected".into(), format!("other-{suffix}")]);
        prop_assert!(validate_identity(&value, &saved, Some("original-nonce")).is_err());
        value.azp = Some("oaiapp-selected".into());
        prop_assert!(validate_identity(&value, &saved, Some("original-nonce")).is_ok());
        value.azp = Some(format!("other-{suffix}"));
        prop_assert!(validate_identity(&value, &saved, Some("original-nonce")).is_err());
    }

    #[test]
    fn an_issued_client_cannot_be_replaced_on_callback(suffix in "[a-z]{1,24}") {
        let saved = registration();
        prop_assert!(saved.callback_client(None).is_ok());
        prop_assert!(saved.callback_client(Some("oaiapp-selected")).is_ok());
        let substituted = format!("oaiapp-other-{suffix}");
        prop_assert!(saved.callback_client(Some(&substituted)).is_err());
        prop_assert!(saved.callback_client(Some("dynamic_agent_client")).is_err());
    }

    #[test]
    fn initial_registration_requires_a_concrete_header_safe_client(
        suffix in "[a-zA-Z0-9_-]{1,64}", control in 0u8..=32,
    ) {
        let mut initial = registration();
        initial.client_id = None;
        initial.subject = None;
        let issued = format!("oaiapp-{suffix}");
        prop_assert!(initial.callback_client(None).is_err());
        prop_assert!(initial.callback_client(Some("dynamic_agent_client")).is_err());
        let accepted = initial.callback_client(Some(&issued));
        prop_assert!(matches!(accepted, Ok(ref actual) if actual == &issued));
        let injected = format!("{issued}{}", char::from(control));
        prop_assert!(initial.callback_client(Some(&injected)).is_err());
        initial.client_id = Some(issued.clone());
        prop_assert!(initial.callback_client(None).is_ok());
        prop_assert!(initial.callback_client(Some(&injected)).is_err());
    }

    #[test]
    fn signed_identity_issuance_and_expiry_bounds_are_enforced(offset in 1u64..3600) {
        let saved = registration();
        let mut value = claims();
        value.exp = value.iat.saturating_sub(offset);
        prop_assert!(validate_identity(&value, &saved, Some("original-nonce")).is_err());
        let mut future = claims();
        future.iat += 7200 + offset;
        future.exp = future.iat + 3600;
        prop_assert!(validate_identity(&future, &saved, Some("original-nonce")).is_err());
    }

    #[test]
    fn registered_account_cannot_restore_a_different_client_or_supplier_host(suffix in "[a-z]{1,24}") {
        let client=format!("registered-{suffix}");
        let fresh=registered_account(None,&client);
        prop_assert!(fresh.is_ok());
        let mut saved=fresh.map_err(|_| proptest::test_runner::TestCaseError::fail("registered account"))?;
        prop_assert!(saved.host_id.is_empty());
        prop_assert!(saved.subject.is_none());
        prop_assert!(registered_account(Some(saved.clone()),&client).is_ok());
        let substituted=format!("other-{suffix}");
        prop_assert!(registered_account(Some(saved.clone()),&substituted).is_err());
        saved.host_id="urn:uuid:supplier-host".into();
        prop_assert!(registered_account(Some(saved),&client).is_err());
    }
}
