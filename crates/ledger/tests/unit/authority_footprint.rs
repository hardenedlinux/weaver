// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Impact, State};
use crate::persistence::scheduler::Scope;
use proptest::{prop_assert_eq, prop_assert_ne, proptest};

proptest! {
    #[test]
    fn local_commit_retires_whole_and_own_but_preserves_peer(origin in 0u64..128, shared in 0u64..128) {
        let own=Scope::Domains([format!("origin-{origin}"),format!("budget-{shared}"),format!("history-{shared}")].into());
        let peer=Scope::Domains([format!("origin-{}",origin+1),format!("budget-{shared}"),format!("history-{shared}")].into());
        let mut state=State::default();
        let whole_before=state.stamp(&Scope::All);let own_before=state.stamp(&own);let peer_before=state.stamp(&peer);
        state.advance(&own,Impact::Origin).expect("local commit");
        prop_assert_ne!(state.stamp(&Scope::All),whole_before);
        prop_assert_ne!(state.stamp(&own),own_before);
        prop_assert_eq!(state.stamp(&peer),peer_before);
    }
}
