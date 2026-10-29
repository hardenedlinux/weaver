//! Deciding-store constraints; there is no budget release without evidence.
/// Native owner boundary for `SCHEMA`.
pub const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS authority (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL,
 fence INTEGER NOT NULL, policy TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS tasks (
 family TEXT PRIMARY KEY, record TEXT NOT NULL,
 budget INTEGER NOT NULL CHECK(budget>0), held INTEGER NOT NULL DEFAULT 0 CHECK(held>=0 AND held<=budget));
CREATE TABLE IF NOT EXISTS operations (
 family TEXT NOT NULL REFERENCES tasks(family), node TEXT NOT NULL,
 digest TEXT NOT NULL, proposal TEXT NOT NULL, reserved INTEGER NOT NULL CHECK(reserved>0),
 state TEXT NOT NULL CHECK(state IN ('queued','unknown','response_received')),
 PRIMARY KEY(family,node));
"#;
