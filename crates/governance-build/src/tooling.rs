// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Typed SDK bindings supplied by Cargo's build-host dependency context.
use crate::ProgramStageRequest;
use std::{fs, io, path::Path};

/// Only linkage is injected; this crate owns package preparation and staging.
/// No erased values, expression parser or runtime authority are introduced.
pub struct PackageTooling<Runtime, Error> {
    pub initialize: fn() -> Result<Runtime, Error>,
    pub configure_paths: fn(&Runtime, &str, &str) -> Result<i32, Error>,
    pub build_package: fn(&Runtime, &str) -> Result<i32, Error>,
    pub build_package_spec: fn(&Runtime, &str, &str) -> Result<i32, Error>,
    pub run_package_main: fn(&Runtime, &str, &[&str]) -> Result<i32, Error>,
    pub stage_package_program: fn(&Runtime, &str, &str, &[&str]) -> Result<i32, Error>,
}

impl<Runtime, Error: std::fmt::Debug> PackageTooling<Runtime, Error> {
    fn runtime(&self, request: &ProgramStageRequest<'_>) -> Runtime {
        let prefix = std::path::Path::new(request.output).join("package");
        let library = prefix.join("lib");
        std::fs::create_dir_all(&library).expect("native build output prefix");
        bind_package_sources(Path::new(request.library), &prefix)
            .expect("native package source inputs");
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
        // The SDK's Build Packages specification owns the program prerequisites.
        // All outputs use Cargo's prefix; the SDK source checkout is read-only.
        let sdk = gerbil_scheme_aot_build::source_workspace()
            .canonicalize()
            .expect("Cargo SDK source");
        assert_eq!(
            (self.build_package_spec)(
                runtime,
                sdk.to_str().expect("SDK source encoding"),
                "gerbil-scheme-rust-program-build-spec",
            )
            .expect("SDK program prerequisites"),
            0
        );
    }
    fn compile_application(&self, runtime: &Runtime, request: &ProgramStageRequest<'_>) {
        assert_eq!(
            (self.build_package)(runtime, request.package).expect("Weaver package build"),
            0
        );
        // The standard Gateway Build owns this first-party module. Only the
        // configured application at the exact package path can use its output.
        if package_application(request) {
            return;
        }
        let compile = |source: &str, module: &str| {
            assert_eq!(
                (self.run_package_main)(
                    runtime,
                    request.package,
                    &["compile-approved-program", source, module],
                )
                .expect("application module build"),
                0
            );
        };
        compile(request.application_source, request.application_module);
    }
    fn stage_application(&self, runtime: &Runtime, request: &ProgramStageRequest<'_>) {
        if package_application(request) {
            stage_published_program(Path::new(request.output));
            return;
        }
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

pub(crate) fn package_application(request: &ProgramStageRequest<'_>) -> bool {
    let relative = match request.application_module {
        "hardenedlinux/weaver/scheme/gateway/provider-program" => {
            "scheme/gateway/provider-program.ss"
        }
        crate::application::QUALIFICATION_APPLICATION => "scheme/gateway/qualification-program.ss",
        _ => return false,
    };
    Path::new(request.application_source) == Path::new(request.package).join(relative)
}

/// Consume Core's published loader plan, preserving its activation stub.
/// The two SDK carriers belong to the Rust host, as in Marlin's ABI linker;
/// no Scheme dependency, discovery pass or replacement loader is introduced.
fn stage_published_program(output: &Path) {
    use serde_json::{Value, json};
    let published =
        output.join("package/lib/hardenedlinux/weaver/programs/scheme/gateway/program.json");
    // This publication is a product of this Cargo build, not a rerun input.
    let mut plan: Value = serde_json::from_reader(
        fs::File::open(&published)
            .expect("Core published Gateway program; native Build with-link required"),
    )
    .expect("Core program manifest");
    let modules = plan
        .get_mut("modules")
        .and_then(Value::as_array_mut)
        .expect("Core compiler module graph");
    let sdk = gerbil_scheme_aot_build::source_workspace();
    let mut carriers = Vec::new();
    for unit in ["utf8", "runtime"] {
        let identity = format!("gerbil-scheme-rust/scheme/{unit}");
        assert!(
            !modules.iter().any(|module| module["module"] == identity),
            "Scheme program imports the Rust SDK carrier: {identity}"
        );
        let source = sdk.join(format!("scheme/generated/{unit}.scm"));
        assert!(
            source.is_file(),
            "Cargo SDK carrier missing: {}",
            source.display()
        );
        println!("cargo:rerun-if-changed={}", source.display());
        carriers.push(json!({"module": identity, "scm": source, "system": false}));
    }
    let position = modules
        .iter()
        .position(|module| {
            !module["module"]
                .as_str()
                .is_some_and(|id| id.starts_with("gerbil/runtime/"))
        })
        .unwrap_or(modules.len());
    modules.splice(position..position, carriers);
    let destination = output.join("program.json");
    let bytes = serde_json::to_vec(&plan).expect("host-bound Core program manifest");
    if fs::read(&destination).as_deref().ok() != Some(bytes.as_slice()) {
        fs::write(destination, bytes).expect("Cargo-owned program manifest");
    }
}

/// Borrow Gerbil's existing package source directory into the fresh Cargo owner.
/// Only `lib` is an output. No dependency discovery, installation or source copy
/// is performed here; native `pkg-root-dir` retains the selected input store.
/// Bind before creating the tooling VM, while this Cargo output has no live owner.
pub(crate) fn bind_package_sources(library: &Path, prefix: &Path) -> io::Result<()> {
    let source = library
        .parent()
        .ok_or_else(|| io::Error::other("input library prefix required"))?
        .join("pkg")
        .canonicalize()?;
    if !source.is_dir() || source.starts_with(prefix.canonicalize()?) {
        return Err(io::Error::other(
            "independent package source directory required",
        ));
    }
    let destination = prefix.join("pkg");
    match fs::symlink_metadata(&destination) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            match destination.canonicalize() {
                Ok(current) if current == source => return Ok(()),
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
            // The old store may have been replaced or removed. Replace only
            // the link in this build's output.
            fs::remove_file(&destination)?;
        }
        Ok(metadata) if metadata.is_dir() => fs::remove_dir(&destination)?,
        Ok(_) => return Err(io::Error::other("package input mount is occupied")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(source, destination)
    }
    #[cfg(windows)]
    {
        std::os::windows::fs::symlink_dir(source, destination)
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
