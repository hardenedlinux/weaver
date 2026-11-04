// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Typed SDK bindings supplied by Cargo's build-host dependency context.
use crate::ProgramStageRequest;

/// Only linkage is injected; this crate owns package preparation and staging.
/// No erased values, expression parser or runtime authority are introduced.
pub struct PackageTooling<Runtime, Error> {
    pub initialize: fn() -> Result<Runtime, Error>,
    pub configure_paths: fn(&Runtime, &str, &str) -> Result<i32, Error>,
    pub build_package: fn(&Runtime, &str) -> Result<i32, Error>,
    pub run_package_main: fn(&Runtime, &str, &[&str]) -> Result<i32, Error>,
    pub stage_package_program: fn(&Runtime, &str, &str, &[&str]) -> Result<i32, Error>,
}

impl<Runtime, Error: std::fmt::Debug> PackageTooling<Runtime, Error> {
    fn runtime(&self, request: &ProgramStageRequest<'_>) -> Runtime {
        let prefix = std::path::Path::new(request.output).join("package");
        let library = prefix.join("lib");
        std::fs::create_dir_all(&library).expect("native build output prefix");
        let libraries =
            std::env::join_paths([library.as_path(), std::path::Path::new(request.library)])
                .expect("build library path list");
        let runtime = (self.initialize)().expect("compiler runtime");
        assert_eq!(
            (self.configure_paths)(
                &runtime,
                prefix.to_str().expect("build prefix encoding"),
                libraries.to_str().expect("build library encoding")
            )
            .expect("package paths"),
            0
        );
        runtime
    }
    fn prepare_sdk(&self, runtime: &Runtime) {
        // The selected SDK's standard package entry owns its complete module graph.
        // All outputs use Cargo's prefix; the SDK source checkout is read-only.
        let sdk = gerbil_scheme_aot_build::source_workspace()
            .canonicalize()
            .expect("Cargo SDK source");
        assert_eq!(
            (self.build_package)(runtime, sdk.to_str().expect("SDK source encoding"))
                .expect("SDK package build"),
            0
        );
    }
    fn compile_application(&self, runtime: &Runtime, request: &ProgramStageRequest<'_>) {
        assert_eq!(
            (self.run_package_main)(
                runtime,
                request.package,
                &[
                    "program",
                    request.application_source,
                    request.application_module
                ]
            )
            .expect("package build"),
            0
        );
    }
    fn stage_application(&self, runtime: &Runtime, request: &ProgramStageRequest<'_>) {
        assert_eq!(
            (self.stage_package_program)(
                runtime,
                request.application_source,
                request.output,
                crate::RUNTIME_IMPORTS
            )
            .expect("program staging"),
            0
        );
    }
}

/// Stage with one affine SDK owner and Cargo-owned outputs; source trees are inputs.
pub fn stage_program<Runtime, Error: std::fmt::Debug>(
    request: ProgramStageRequest<'_>,
    tooling: PackageTooling<Runtime, Error>,
) {
    let previous = std::env::current_dir().expect("build directory");
    std::env::set_current_dir(request.package).expect("package directory");
    let runtime = tooling.runtime(&request);
    tooling.prepare_sdk(&runtime);
    tooling.compile_application(&runtime, &request);
    tooling.stage_application(&runtime, &request);
    drop(runtime);
    std::env::set_current_dir(previous).expect("restore build directory");
}
