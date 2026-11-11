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
    let mut args = std::env::args_os().skip(1);
    let usage = || {
        weaver_contracts::Error::Invalid(concat!(
            "usage: weaver-server [prepare [--config path]",
            " | reconcile-kubernetes --config path (kubernetes feature)",
            " | import-provider json|yaml source review]"
        ))
    };
    let result = match args.next().as_deref() {
        None => weaver_server::entrypoint::run(),
        Some(command) if command == "prepare" => {
            match (args.next().as_deref(), args.next(), args.next()) {
                (None, None, None) => weaver_server::entrypoint::prepare(None),
                (Some(flag), Some(path), None) if flag == "--config" => {
                    weaver_server::entrypoint::prepare(Some(path.into()))
                }
                _ => Err(usage()),
            }
        }
        Some(command) if command == "import-provider" => {
            match (
                args.next().as_deref(),
                args.next(),
                args.next(),
                args.next(),
            ) {
                (Some(format), Some(source), Some(review), None)
                    if format == "json" || format == "yaml" =>
                {
                    weaver_server::entrypoint::import_provider(
                        std::path::Path::new(&source),
                        format == "yaml",
                        std::path::Path::new(&review),
                    )
                }
                _ => Err(usage()),
            }
        }
        #[cfg(feature = "kubernetes")]
        Some(command) if command == "reconcile-kubernetes" => {
            match (args.next().as_deref(), args.next(), args.next()) {
                (Some(flag), Some(path), None) if flag == "--config" => {
                    weaver_server::entrypoint::reconcile_kubernetes(path.into())
                }
                _ => Err(usage()),
            }
        }
        _ => Err(usage()),
    };
    if let Err(error) = result {
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
