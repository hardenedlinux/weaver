// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Validated native build-host arguments; no generated Scheme expressions.
use std::path::Path;

/// Explicit runtime imports required by the Gateway bridge.
pub const RUNTIME_IMPORTS: &[&str] = &[
    ":gerbil/expander",
    ":hardenedlinux/weaver/scheme/governance/interface",
    ":hardenedlinux/weaver/scheme/policy/interface",
    ":hardenedlinux/weaver/scheme/gateway/interface",
];

/// Borrowed inputs to the SDK's native package and graph staging APIs.
pub struct ProgramStageRequest<'a> {
    pub package: &'a str,
    pub library: &'a str,
    pub output: &'a str,
    pub application_source: &'a str,
    pub application_module: &'a str,
}
impl<'a> ProgramStageRequest<'a> {
    pub fn new(
        package: &'a Path,
        library: &'a Path,
        output: &'a Path,
        application: &'a crate::ProgramApplication,
    ) -> Result<Self, &'static str> {
        fn path(value: &Path) -> Result<&str, &'static str> {
            if !value.is_absolute() {
                return Err("absolute path required");
            }
            let value = value.to_str().ok_or("path encoding")?;
            if value.contains('\0') {
                return Err("path contains NUL");
            }
            Ok(value)
        }
        if library.file_name() != Some(std::ffi::OsStr::new("lib")) {
            return Err("package library directory required");
        }
        Ok(Self {
            package: path(package)?,
            library: path(library)?,
            output: path(output)?,
            application_source: path(application.source())?,
            application_module: application.module(),
        })
    }
}
