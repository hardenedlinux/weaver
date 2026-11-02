//! Closed-store fault images include the durable `Turso` WAL, not transient SHM.
use std::{
    ffi::OsString,
    fs, io,
    path::{Path, PathBuf},
};

fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = OsString::from(path.as_os_str());
    name.push(suffix);
    PathBuf::from(name)
}
fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}
/// Copy a complete durable image only after all source/destination owners close.
/// This is fault injection, not a live backup or a second storage implementation.
pub fn copy_closed(source: impl AsRef<Path>, destination: impl AsRef<Path>) -> io::Result<()> {
    let (source, destination) = (source.as_ref(), destination.as_ref());
    fs::copy(source, destination)?;
    let source_wal = sidecar(source, "-wal");
    let destination_wal = sidecar(destination, "-wal");
    match fs::copy(&source_wal, &destination_wal) {
        Ok(_) => (),
        Err(e) if e.kind() == io::ErrorKind::NotFound => remove_if_present(&destination_wal)?,
        Err(e) => return Err(e),
    }
    let source_log = source.with_extension("db-log");
    let destination_log = destination.with_extension("db-log");
    match fs::copy(&source_log, &destination_log) {
        Ok(_) => (),
        Err(e) if e.kind() == io::ErrorKind::NotFound => remove_if_present(&destination_log)?,
        Err(e) => return Err(e),
    }
    // No process may retain this derived index across a whole-image restore.
    remove_if_present(&sidecar(destination, "-shm"))?;
    Ok(())
}
