// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Gateway RPC owner.
mod rpc;
mod service;

pub(crate) use service::Gateway;
pub use service::{ResponseStream, serve_grpc, serve_grpc_with_runtime};
