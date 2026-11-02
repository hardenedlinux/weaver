//! One native database per canonical file; MVCC has exactly one process owner.
use super::{driver, one};
use futures_executor::block_on;
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock, RwLock, Weak},
};

/// Explicit storage profile. Existing nonempty databases are never converted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Journal {
    Wal,
    Mvcc,
}
pub(super) struct Owner {
    pub database: driver::Database,
    pub journal: Journal,
    pub gate: RwLock<()>,
    pub families: [Mutex<()>; 64],
    // Drop the engine before releasing process custody. Never unlink this file.
    _custody: File,
}
type Owners = BTreeMap<PathBuf, Weak<Owner>>;
static OWNERS: OnceLock<Mutex<Owners>> = OnceLock::new();
pub(super) fn error(message: impl ToString) -> driver::Error {
    driver::Error::Misuse(message.to_string())
}

pub(super) fn open(path: &Path, requested: Option<Journal>) -> driver::Result<Arc<Owner>> {
    if path.as_os_str().is_empty() || path == Path::new(":memory:") {
        return Err(error("durable storage path required"));
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map_err(error)?;
    let path = path.canonicalize().map_err(error)?;
    let mut owners = OWNERS.get_or_init(Mutex::default).lock().map_err(error)?;
    if let Some(owner) = owners.get(&path).and_then(Weak::upgrade) {
        if requested.is_some_and(|mode| mode != owner.journal) {
            return Err(error("live storage journal mismatch"));
        }
        return Ok(owner);
    }
    owners.retain(|_, owner| owner.strong_count() != 0);
    let journal = requested.unwrap_or(Journal::Wal);
    if journal == Journal::Mvcc && path.extension().is_none_or(|extension| extension != "db") {
        return Err(error("MVCC custody requires a canonical .db path"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if file.metadata().map_err(error)?.nlink() != 1 {
            return Err(error("storage hard-link aliases are not supported"));
        }
    }
    let mut custody = path.as_os_str().to_os_string();
    custody.push(".weaver-owner");
    let custody = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(PathBuf::from(custody))
        .map_err(error)?;
    match journal {
        Journal::Wal => custody.try_lock_shared().map_err(error)?,
        Journal::Mvcc => custody.try_lock().map_err(error)?,
    }
    let fresh = file.metadata().map_err(error)?.len() == 0;
    let builder = driver::Builder::new_local(
        path.to_str()
            .ok_or_else(|| error("storage path encoding"))?,
    );
    let database = block_on(
        builder
            .experimental_multiprocess_wal(journal == Journal::Wal)
            .build(),
    )?;
    let connection = database.connect()?;
    if fresh && journal == Journal::Mvcc {
        let _: String = one(&connection, "PRAGMA journal_mode=mvcc", (), |row| {
            row.get(0)
        })?;
    }
    let mode: String = one(&connection, "PRAGMA journal_mode", (), |row| row.get(0))?;
    if mode
        != match journal {
            Journal::Wal => "wal",
            Journal::Mvcc => "mvcc",
        }
    {
        return Err(error(
            "storage journal mismatch; implicit conversion refused",
        ));
    }
    let owner = Arc::new(Owner {
        database,
        journal,
        gate: RwLock::new(()),
        families: std::array::from_fn(|_| Mutex::new(())),
        _custody: custody,
    });
    owners.insert(path, Arc::downgrade(&owner));
    Ok(owner)
}

pub(super) fn stripe(family: &str) -> usize {
    // Collisions only reduce concurrency; canonical family identity is unchanged.
    family.bytes().fold(0usize, |hash, byte| {
        hash.wrapping_mul(31).wrapping_add(usize::from(byte))
    }) % 64
}
