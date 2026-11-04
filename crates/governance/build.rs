// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

fn main() {
    weaver_governance_build::build_program(|request| {
        #[cfg(feature = "scheme-program")]
        weaver_governance_build::stage_program(
            request,
            weaver_governance_build::PackageTooling {
                initialize: gerbil_scheme::GerbilRuntime::initialize,
                configure_paths: gerbil_scheme::GerbilRuntime::configure_package_paths,
                build_package: gerbil_scheme::GerbilRuntime::build_package,
                run_package_main: gerbil_scheme::GerbilRuntime::run_package_main,
                stage_package_program: gerbil_scheme::GerbilRuntime::stage_package_program,
            },
        );
        #[cfg(not(feature = "scheme-program"))]
        let _ = request;
    });
}
