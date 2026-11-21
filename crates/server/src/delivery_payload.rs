// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Inert prepared output. Both transports consume the same native delivery cursor.

pub(crate) enum Payload {
    Rpc(crate::pb::ProviderFrame),
    Sse(Vec<u8>),
}
