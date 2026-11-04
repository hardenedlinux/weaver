// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use std::{sync::Arc, time::Duration};
use tokio::time::Instant;

#[derive(Clone)]
pub(super) struct AccessToken {
    pub(super) value: Arc<str>,
    pub(super) expires: Instant,
}

pub(super) fn reusable(cached: Option<&AccessToken>) -> Option<AccessToken> {
    cached
        .filter(|token| {
            token.expires.saturating_duration_since(Instant::now()) > Duration::from_secs(30)
        })
        .cloned()
}
