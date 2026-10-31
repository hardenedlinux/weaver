//! Deciding-store constraints; there is no budget release without evidence.
/// Native owner boundary for `SCHEMA`.
pub const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS authority_pending (
 operation_id TEXT PRIMARY KEY, digest TEXT NOT NULL, proposal TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL,
 fence INTEGER NOT NULL, policy TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority_schema (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority_publications (
 operation_id TEXT PRIMARY KEY, digest TEXT NOT NULL, request TEXT NOT NULL, receipt TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS tasks (
 family TEXT PRIMARY KEY, record TEXT NOT NULL,
 budget INTEGER NOT NULL CHECK(budget>0), held INTEGER NOT NULL DEFAULT 0 CHECK(held>=0 AND held<=budget));
CREATE TABLE IF NOT EXISTS provider_profiles (
 id TEXT PRIMARY KEY, digest TEXT NOT NULL, record TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS task_profile_semantics ON tasks (
 json_extract(record,'$.profile'),
 json_array(json_extract(record,'$.provider_profile.id'),json_extract(record,'$.provider_profile.protocol'),
  json_extract(record,'$.provider_profile.max_output_tokens'),json_extract(record,'$.provider_profile.max_messages'),
  json_extract(record,'$.provider_profile.max_body_bytes'),
  json_remove(json_extract(record,'$.provider_profile'),'$.id','$.protocol','$.max_output_tokens','$.max_messages','$.max_body_bytes')))
 WHERE json_type(record,'$.provider_profile') IS NOT NULL AND json_type(record,'$.provider_profile') != 'null';
CREATE TABLE IF NOT EXISTS operations (
 family TEXT NOT NULL REFERENCES tasks(family), node TEXT NOT NULL,
 digest TEXT NOT NULL, proposal TEXT NOT NULL, reserved INTEGER NOT NULL CHECK(reserved>0),
 state TEXT NOT NULL CHECK(state IN ('queued','unknown','response_received')),
 PRIMARY KEY(family,node));
CREATE TABLE IF NOT EXISTS execution_claims (
 family TEXT NOT NULL, node TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('request','stream')), PRIMARY KEY(family,node));
INSERT OR IGNORE INTO execution_claims SELECT family,node,'request' FROM operations;
CREATE TABLE IF NOT EXISTS streams (
 family TEXT NOT NULL REFERENCES tasks(family), node TEXT NOT NULL, contract TEXT NOT NULL, digest TEXT NOT NULL,
 generation INTEGER NOT NULL DEFAULT 0, owner TEXT, owner_fence INTEGER,
 PRIMARY KEY(family,node));
CREATE TABLE IF NOT EXISTS stream_messages (
 family TEXT NOT NULL, node TEXT NOT NULL, message TEXT NOT NULL, ordinal INTEGER NOT NULL,
 digest TEXT NOT NULL, proposal TEXT NOT NULL, reserved INTEGER NOT NULL CHECK(reserved>0),
 auth_revision INTEGER NOT NULL, auth_fence INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('queued','active','unknown','complete')), cursor INTEGER NOT NULL DEFAULT 0,
 next_sequence INTEGER NOT NULL DEFAULT 0, payload BLOB NOT NULL,
 PRIMARY KEY(family,node,message), FOREIGN KEY(family,node) REFERENCES streams(family,node));
CREATE TABLE IF NOT EXISTS stream_ranges (
 family TEXT NOT NULL, node TEXT NOT NULL, message TEXT NOT NULL, sequence INTEGER NOT NULL,
 offset INTEGER NOT NULL, length INTEGER NOT NULL, written INTEGER,
 state TEXT NOT NULL CHECK(state IN ('unknown','complete','not_sent','partial')),
 PRIMARY KEY(family,node,message,sequence),
 FOREIGN KEY(family,node,message) REFERENCES stream_messages(family,node,message));
CREATE TABLE IF NOT EXISTS provider_runs (
 family TEXT NOT NULL REFERENCES tasks(family), node TEXT NOT NULL, digest TEXT NOT NULL, plan TEXT NOT NULL,
 reserved INTEGER NOT NULL CHECK(reserved>0), state TEXT NOT NULL CHECK(state IN ('queued','unknown','complete')),
 target TEXT, dispatched INTEGER NOT NULL DEFAULT 0, next_event INTEGER NOT NULL DEFAULT 0,
 PRIMARY KEY(family,node));
CREATE TABLE IF NOT EXISTS provider_releases (
 family TEXT NOT NULL, node TEXT NOT NULL, sequence INTEGER NOT NULL, length INTEGER NOT NULL, digest TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('unknown','released')), PRIMARY KEY(family,node,sequence),
 FOREIGN KEY(family,node) REFERENCES provider_runs(family,node));
"#;
