// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Deployment entrypoint; runtime composition belongs to the server library.
#![forbid(unsafe_code)]
fn main() {
    eprintln!(
        "weaver startup stage=process-main clock={:?}",
        std::time::SystemTime::now()
    );
    if let Err(error) = weaver_server::entrypoint::run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
    let wall = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    eprintln!(
        "weaver shutdown stage=main-returning wall_ns={}",
        wall.as_nanos()
    );
}
