// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Approved Gerbil paths, compiler graph staging and native archive composition.
use crate::ProgramStageRequest;
use gerbil_scheme_aot_build::{
    NativeHeaderInput, ProgramArchiveContract, ProgramArchiveObservation, ProgramArchiveObserver,
    ProgramArchiveRequest, build_program_archive_with_contract, discover_gambit_gsc_from_env,
};
use std::{env, path::PathBuf};
struct Progress<'a> {
    output: &'a std::path::Path,
}
impl ProgramArchiveObserver for Progress<'_> {
    fn observe(&self, event: ProgramArchiveObservation<'_>) {
        eprintln!("governance-program: {event}");
    }
    fn observe_source_input(&self, path: &std::path::Path) {
        if !path.starts_with(self.output) {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
}
struct BuildPaths {
    root: PathBuf,
    out: PathBuf,
    stage: PathBuf,
    library: PathBuf,
    application: crate::ProgramApplication,
}
impl BuildPaths {
    fn from_env() -> Self {
        let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("manifest"))
            .join("../..")
            .canonicalize()
            .expect("root");
        let application = if env::var_os("CARGO_FEATURE_SCHEME_QUALIFICATION").is_some() {
            assert!(
                env::var_os("WEAVER_GOVERNANCE_APPLICATION").is_none()
                    && env::var_os("WEAVER_GOVERNANCE_APPLICATION_SOURCE").is_none(),
                "qualification and approved application are mutually exclusive"
            );
            crate::ProgramApplication::qualification(
                &root,
                &env::var("PROFILE").expect("Cargo profile"),
            )
            .expect("qualification build profile")
        } else {
            let application_source = PathBuf::from(
                env::var_os("WEAVER_GOVERNANCE_APPLICATION_SOURCE")
                    .expect("explicit approved Scheme application source required"),
            )
            .canonicalize()
            .expect("approved application source");
            crate::ProgramApplication::approved(
                &env::var("WEAVER_GOVERNANCE_APPLICATION")
                    .expect("explicit approved Scheme application module required"),
                &application_source,
            )
            .expect("approved application module")
        };
        println!("cargo:rerun-if-changed={}", application.source().display());
        let out = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo output"));
        let stage = out.join("program");
        std::fs::create_dir_all(&stage).expect("program staging");
        let library =
            PathBuf::from(env::var_os("GERBIL_PATH").expect("isolated Gerbil prefix")).join("lib");
        Self {
            root,
            out,
            stage,
            library,
            application,
        }
    }
    fn archive(&self) {
        let gsc = discover_gambit_gsc_from_env().expect("paired Gambit compiler");
        let include = self.root.join("crates/policy-ffi/include");
        let headers = [include.join("weaver_policy.h")];
        let required = [
            "gerbil-scheme-rust/scheme/runtime",
            "hardenedlinux/weaver/scheme/gateway/compiled",
            self.application.module(),
        ];
        let receipt = build_program_archive_with_contract(
            ProgramArchiveRequest {
                manifest: &self.stage.join("program.json"),
                gsc: &gsc,
                archive_name: "weaver_governance_program",
                linker_name: "weaver_governance_program",
                out_dir: &self.out.join("archive"),
            },
            ProgramArchiveContract {
                required_modules: &required,
                forbidden_modules: self.application.forbidden_modules(),
                linker_main_symbol: "weaver_governance_program_main",
                additional_objects: &[],
                native_headers: &[NativeHeaderInput {
                    include_directory: &include,
                    header_files: &headers,
                }],
            },
            &Progress { output: &self.out },
        )
        .expect("native program archive");
        for directive in receipt.cargo_directives {
            println!("{}", directive.line());
        }
    }
}
/// Stage an explicit application and emit native linker directives from the Gerbil.
pub fn build_program(stage: impl FnOnce(ProgramStageRequest<'_>)) {
    for name in [
        "GERBIL_HOME",
        "GERBIL_PATH",
        "GERBIL_LOADPATH",
        "PKG_CONFIG_PATH",
        "PKG_CONFIG_LIBDIR",
        "PKG_CONFIG_SYSROOT_DIR",
        "GERBIL_GXI",
        "GERBIL_GXC",
        "GERBIL_GSC",
        "WEAVER_GOVERNANCE_APPLICATION",
        "WEAVER_GOVERNANCE_APPLICATION_SOURCE",
    ] {
        println!("cargo:rerun-if-env-changed={name}");
    }
    if env::var_os("CARGO_FEATURE_SCHEME_PROGRAM").is_none() {
        return;
    }
    let paths = BuildPaths::from_env();
    stage(
        ProgramStageRequest::new(
            &paths.root,
            &paths.library,
            &paths.stage,
            &paths.application,
        )
        .expect("native staging arguments"),
    );
    paths.archive();
}
