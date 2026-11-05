// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Build-owned application selection, never runtime source/module dispatch.
use std::path::{Path, PathBuf};
/// Test application forbidden in an approved production graph.
pub const QUALIFICATION_APPLICATION: &str = "hardenedlinux/weaver/t/fixtures/governance-program";
/// Test Governor/Profile implementation forbidden in a production graph.
pub const QUALIFICATION_CONTROL: &str = "hardenedlinux/weaver/t/fixtures/governed-control";
/// One explicit build-owned application; validity does not prove authenticity.
#[derive(Clone, Debug)]
pub struct ProgramApplication {
    module: String,
    source: PathBuf,
    qualification: bool,
}
impl ProgramApplication {
    /// Syntax validity is not approval: the operator owns graph review/build.
    pub fn approved(module: &str, source: &Path) -> Result<Self, &'static str> {
        if !valid_module(module)
            || module.starts_with("hardenedlinux/weaver/t/")
            || !source.is_absolute()
            || source.extension().is_none_or(|ext| ext != "ss")
            || source
                .to_str()
                .is_none_or(|path| path.len() > 4096 || path.contains('\0'))
        {
            return Err("explicit approved application module required");
        }
        Ok(Self {
            module: module.into(),
            source: source.into(),
            qualification: false,
        })
    }
    pub(crate) fn qualification(root: &Path, profile: &str) -> Result<Self, &'static str> {
        if profile != "debug" {
            return Err("qualification application is restricted to debug test builds");
        }
        Ok(Self {
            module: QUALIFICATION_APPLICATION.into(),
            source: root.join("t/fixtures/governance-program.ss"),
            qualification: true,
        })
    }
    /// Validated module identifier, without Scheme reader syntax or a path.
    pub fn module(&self) -> &str {
        &self.module
    }
    pub(crate) fn source(&self) -> &Path {
        &self.source
    }
    pub(crate) fn forbidden_modules(&self) -> &'static [&'static str] {
        if self.qualification {
            &[]
        } else {
            &[QUALIFICATION_APPLICATION, QUALIFICATION_CONTROL]
        }
    }
}
fn valid_module(module: &str) -> bool {
    !module.is_empty()
        && module.len() <= 256
        && module.split('/').all(|segment| {
            !segment.is_empty()
                && segment
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        })
}
