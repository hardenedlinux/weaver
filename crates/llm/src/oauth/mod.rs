// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! OAuth acquisition, supplier identity validation and tracked credential persistence.

mod attempts;
mod copilot;
mod credentials;
mod exchange;
mod exchange_types;
mod http;
mod identity;
mod owner;
mod settings;
mod store;

pub use attempts::{AuthorizationAttempt, DeviceAttempt};
pub(crate) use copilot::headers as copilot_headers;
pub use identity::AccountIdentity;
pub(crate) use identity::discover_oidc;
pub use owner::OAuthSession;
pub(crate) use settings::{
    CopilotConfiguration, OAuthConfiguration, OidcConfiguration, OpenAiConfiguration,
};

pub use exchange_types::DelegatedCredential;
pub(crate) use exchange_types::ExchangeConfiguration;
