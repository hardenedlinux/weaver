//! Development-only compiler entry using the upstream SDK selection boundary.
//! Go owns orchestration. This executable never participates in request IPC.
use std::{env, path::PathBuf, thread};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cores = thread::available_parallelism()?.get().to_string();
    eprintln!("Scheme build available-process-cpus={cores}");
    if env::args().nth(1).as_deref() == Some("resources") {
        return Ok(());
    }
    let compiler = PathBuf::from(env::var("WEAVER_CONTROL_SCHEME_COMPILER")?);
    if !compiler.is_absolute() || compiler.file_name().is_none() {
        return Err("explicit absolute Gerbil compiler required".into());
    }
    if let Some(owner @ ("dependencies" | "core")) = env::args().nth(1).as_deref() {
        let source = PathBuf::from(env::var(if owner == "core" {
            "WEAVER_SCHEME_CORE_SOURCE"
        } else {
            "WEAVER_SCHEME_POO_SOURCE"
        })?)
        .canonicalize()?;
        let mut command = gerbil_scheme_aot_build::gerbil_command(&compiler);
        // Preserve the pinned package's declared Darwin build environment.
        if cfg!(target_os = "macos") {
            command
                .env_remove("MACOSX_DEPLOYMENT_TARGET")
                .env("COMPILER_PATH", "/usr/bin");
        }
        let status = command
            .arg("-:max-heap=2G,debug=q")
            .arg(source.join("build.ss"))
            .arg("compile")
            .env("GERBIL_BUILD_CORES", &cores)
            .current_dir(&source)
            .status()?;
        if !status.success() {
            return Err(format!("declared Scheme {owner} package build failed: {status}").into());
        }
        return Ok(());
    }
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()?;
    // Deferred POO module actions keep C FFI out of source discovery. The sole
    // root package entry owns both module and foreign-code compilation.
    let mut command = gerbil_scheme_aot_build::gerbil_command(&compiler);
    if env::args().nth(1).as_deref() == Some("agentic") {
        command.arg("-:max-heap=2G,debug=q");
    }
    command.current_dir(&root).arg(root.join("build.ss"));
    if env::args().nth(1).as_deref() == Some("agentic") {
        command.arg("dependencies");
    }
    let status = command
        .arg("compile")
        .env("GERBIL_BUILD_CORES", &cores)
        .status()?;
    if !status.success() {
        return Err(format!("Weaver root Scheme build failed: {status}").into());
    }
    Ok(())
}
