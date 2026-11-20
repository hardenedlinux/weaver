// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Separate terminal usage issuer process.

#![forbid(unsafe_code)]

fn main() {
    let mut args = std::env::args_os().skip(1);
    let result = match (args.next(), args.next(), args.next()) {
        (Some(family), Some(node), None) => match (family.into_string(), node.into_string()) {
            (Ok(family), Ok(node)) => weaver_server::entrypoint::meter(family, node),
            _ => Err(weaver_contracts::Error::Invalid(
                "metering operation encoding",
            )),
        },
        _ => Err(weaver_contracts::Error::Invalid(
            "usage: weaver-meter FAMILY NODE",
        )),
    };
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
