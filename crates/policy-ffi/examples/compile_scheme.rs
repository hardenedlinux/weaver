//! Development-only compiler entry using the upstream SDK selection boundary.
//! Go owns orchestration. This executable never participates in request IPC.
use std::{
    env, fs,
    path::{Path, PathBuf},
    thread,
};

fn pkg_path(path: &Path) -> Result<String, Box<dyn std::error::Error>> {
    let value = path.to_str().ok_or("pkg-config paths must be UTF-8")?;
    if value.contains(['\n', '\r', '"', '\\']) || value.contains("${") {
        return Err("pkg-config path framing is invalid".into());
    }
    Ok(value.to_owned())
}

// Cargo's example output sits inside the selected profile output directory.
// This supports CARGO_TARGET_DIR and custom profiles without target/debug paths.
fn write_policy_pkg_config() -> Result<(), Box<dyn std::error::Error>> {
    let executable = env::current_exe()?.canonicalize()?;
    let profile = executable
        .parent()
        .and_then(Path::parent)
        .ok_or("Cargo profile directory absent")?;
    let library = env::var_os("WEAVER_POLICY_LIBRARY")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            profile.join(format!(
                "{}{}{}",
                env::consts::DLL_PREFIX,
                env!("CARGO_PKG_NAME").replace('-', "_"),
                env::consts::DLL_SUFFIX
            ))
        });
    let include = env::var_os("WEAVER_POLICY_INCLUDE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("include"));
    if !library.is_absolute() || !library.is_file() || !include.is_absolute() || !include.is_dir() {
        return Err("Cargo FFI artifact and public include directory must exist".into());
    }
    let metadata = PathBuf::from(env::var("WEAVER_POLICY_PKG_CONFIG")?);
    if !metadata.is_absolute() {
        return Err("absolute isolated pkg-config output required".into());
    }
    fs::create_dir_all(metadata.parent().ok_or("pkg-config directory absent")?)?;
    let libdir = library.parent().ok_or("FFI library directory absent")?;
    fs::write(
        metadata,
        format!(
            "libdir={}\nincludedir={}\nlibrary={}\n\nName: {}\nDescription: Weaver Cedar Policy C ABI\nVersion: {}\nLibs: \"${{library}}\" -Wl,-rpath,\"${{libdir}}\"\nCflags: -I\"${{includedir}}\"\n",
            pkg_path(libdir)?,
            pkg_path(&include)?,
            pkg_path(&library)?,
            env!("CARGO_PKG_NAME"),
            env!("CARGO_PKG_VERSION")
        ),
    )?;
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cores = thread::available_parallelism()?.get().to_string();
    eprintln!("Scheme build available-process-cpus={cores}");
    if env::args().nth(1).as_deref() == Some("resources") {
        return Ok(());
    }
    if env::args().nth(1).as_deref() == Some("pkg-config") {
        return write_policy_pkg_config();
    }
    let compiler = PathBuf::from(env::var("WEAVER_CONTROL_SCHEME_COMPILER")?);
    if !compiler.is_absolute() || compiler.file_name().is_none() {
        return Err("explicit absolute Gerbil compiler required".into());
    }
    let package_tool = env::var_os("WEAVER_SCHEME_TOOL").unwrap_or_else(|| "gerbil".into());
    if let Some(owner @ ("dependencies" | "core")) = env::args().nth(1).as_deref() {
        let source = PathBuf::from(env::var(if owner == "core" {
            "WEAVER_SCHEME_CORE_SOURCE"
        } else {
            "WEAVER_SCHEME_POO_SOURCE"
        })?)
        .canonicalize()?;
        let mut command = gerbil_scheme_aot_build::gerbil_command(&package_tool);
        // The selected SDK and caller own compiler discovery and COMPILER_PATH.
        if cfg!(target_os = "macos") {
            command.env_remove("MACOSX_DEPLOYMENT_TARGET");
        }
        let status = command
            .arg("build")
            .arg("-g")
            .arg(env::var(if owner == "core" {
                "WEAVER_SCHEME_CORE_PACKAGE"
            } else {
                "WEAVER_SCHEME_POO_PACKAGE"
            })?)
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
    write_policy_pkg_config()?;
    // Deferred POO module actions keep C FFI out of source discovery. The sole
    // root package entry owns both module and foreign-code compilation.
    let mut command = gerbil_scheme_aot_build::gerbil_command(&package_tool);
    let metadata = PathBuf::from(env::var("WEAVER_POLICY_PKG_CONFIG")?);
    let mut search = vec![
        metadata
            .parent()
            .ok_or("pkg-config directory absent")?
            .to_path_buf(),
    ];
    if let Some(inherited) = env::var_os("PKG_CONFIG_PATH") {
        search.extend(env::split_paths(&inherited));
    }
    command.env("PKG_CONFIG_PATH", env::join_paths(search)?);
    command.env(
        "WEAVER_POLICY_PKG_CONFIG_PACKAGE",
        metadata
            .file_stem()
            .ok_or("pkg-config package identity absent")?,
    );
    command.current_dir(&root).args(["build", "-g"]);
    let status = command.env("GERBIL_BUILD_CORES", &cores).status()?;
    if !status.success() {
        return Err(format!("Weaver root Scheme build failed: {status}").into());
    }
    Ok(())
}
