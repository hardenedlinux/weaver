// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Explicit standalone fixture owner. Production always borrows the server reactor.
//! The endpoint/benchmark owns this value until its drivers and server thread
//! have naturally drained; no detached provider tasks are spawned on this pool.
pub fn fixture_runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("fixture reactor")
}
