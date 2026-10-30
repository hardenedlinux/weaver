//! Development-only compiler entry using the upstream SDK selection boundary.
//! Go owns orchestration. This executable never participates in request IPC.
use std::{env, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let compiler = PathBuf::from(env::var("WEAVER_CONTROL_SCHEME_COMPILER")?);
    if !compiler.is_absolute() || compiler.file_name().is_none() {
        return Err("explicit absolute Gerbil compiler required".into());
    }
    if env::args().nth(1).as_deref() == Some("dependencies") {
        let source = PathBuf::from(env::var("WEAVER_SCHEME_POO_SOURCE")?).canonicalize()?;
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
            .env("GERBIL_BUILD_CORES", "1")
            .current_dir(&source)
            .status()?;
        if !status.success() {
            return Err(format!("declared Gerbil POO package build failed: {status}").into());
        }
        return Ok(());
    }
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()?;
    // Deferred POO module actions keep C FFI out of source discovery. The sole
    // root package entry owns both module and foreign-code compilation.
    let status = gerbil_scheme_aot_build::gerbil_command(&compiler)
        .current_dir(&root)
        .arg(root.join("build.ss"))
        .arg("compile")
        .env("GERBIL_BUILD_CORES", "1")
        .status()?;
    if !status.success() {
        return Err(format!("Weaver root Scheme build failed: {status}").into());
    }
    Ok(())
}
