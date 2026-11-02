//! Publish Cargo's actual Policy FFI artifact to the standard pkg-config boundary.
use std::{
    env, fs,
    path::{Path, PathBuf},
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
    write_policy_pkg_config()
}
