// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{ApiEndpoint, ApiLease, CopilotSettings, ParentCredential};
use proptest::{
    prop_assert, proptest,
    test_runner::{Config, RngSeed},
};

fn settings() -> CopilotSettings {
    CopilotSettings {
        api_base: "https://api.githubcopilot.com".into(),
        api_token_url: "https://api.github.com/copilot_internal/v2/token".into(),
    }
}

proptest! {
    #![proptest_config(Config {cases:64,rng_seed:RngSeed::Fixed(293),..Config::default()})]
    #[test]
    fn a_parent_without_server_expiry_does_not_gain_an_invented_lifetime(
        issued in 1u64..1_000_000, elapsed in 1u64..100_000,
    ) {
        let mut parent = ParentCredential {access:"upstream-only".into(),issued_at:issued,expires_at:None,
            refresh:None,refresh_expires_at:None};
        prop_assert!(parent.valid(issued+elapsed));
        prop_assert!(!parent.valid(issued-1));
        parent.expires_at=Some(issued+elapsed);
        prop_assert!(!parent.valid(issued+elapsed));
        prop_assert!(parent.valid(issued+elapsed-1));
    }

    #[test]
    fn a_refresh_secret_is_unavailable_after_its_own_expiry(
        issued in 1u64..1_000_000, lifetime in 1u64..100_000,
    ) {
        let parent=ParentCredential {access:"parent".into(),issued_at:issued,expires_at:Some(issued+lifetime),
            refresh:Some("rotating-refresh".into()),refresh_expires_at:Some(issued+lifetime+10)};
        prop_assert!(parent.refresh_token(issued+lifetime).is_some());
        prop_assert!(parent.refresh_token(issued+lifetime+10).is_none());
        prop_assert!(parent.refresh_token(issued-1).is_none());
    }

    #[test]
    fn api_refresh_hints_cannot_extend_absolute_expiry_or_change_destination(
        now in 1u64..1_000_000, lifetime in 31u64..100_000,
        refresh in 1u64..200_000, suffix in "[a-z]{1,24}",
    ) {
        let mut lease = ApiLease {token:"api-only".into(),expires_at:now+lifetime,refresh_in:refresh,
            endpoints:Some(ApiEndpoint {api:Some("https://api.githubcopilot.com/".into())})};
        prop_assert!(lease.validate(&settings(),now).is_ok());
        prop_assert!(lease.validate(&settings(),now+lifetime).is_err());
        lease.endpoints=Some(ApiEndpoint {api:Some(format!("https://api.githubcopilot.com.{suffix}.invalid"))});
        prop_assert!(lease.validate(&settings(),now).is_err());
        lease.endpoints=None;
        lease.refresh_in=0;
        prop_assert!(lease.validate(&settings(),now).is_err());
        lease.refresh_in=u64::MAX;
        prop_assert!(lease.validate(&settings(),now).is_err());
    }
}
