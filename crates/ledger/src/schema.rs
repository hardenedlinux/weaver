// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Deciding-store constraints; there is no budget release without evidence.
/// Native owner boundary for `SCHEMA`.
pub const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS original_tasks (
 task_key TEXT PRIMARY KEY, family TEXT NOT NULL UNIQUE, origin TEXT NOT NULL UNIQUE,
 task_digest TEXT NOT NULL, binding_digest TEXT NOT NULL, publication TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS task_admissions (
 operation_id TEXT PRIMARY KEY, digest TEXT NOT NULL, receipt TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS budget_domains (
 id TEXT PRIMARY KEY, root TEXT NOT NULL, declared_limit INTEGER NOT NULL CHECK(declared_limit>0),
 ceiling INTEGER NOT NULL CHECK(ceiling>0 AND ceiling<=declared_limit), held INTEGER NOT NULL CHECK(held>=0 AND held<=ceiling), epoch INTEGER NOT NULL CHECK(epoch>0));
CREATE TABLE IF NOT EXISTS history_domains (
 id TEXT PRIMARY KEY, root TEXT NOT NULL, events INTEGER NOT NULL CHECK(events>=0), epoch INTEGER NOT NULL CHECK(epoch>0));
CREATE TABLE IF NOT EXISTS execution_origins (
 id TEXT PRIMARY KEY, canonical_family TEXT NOT NULL UNIQUE, binding TEXT NOT NULL,
 budget_root TEXT NOT NULL, history_root TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS origins_budget ON execution_origins(budget_root);
CREATE INDEX IF NOT EXISTS origins_history ON execution_origins(history_root);
CREATE TABLE IF NOT EXISTS family_origins (family TEXT PRIMARY KEY, origin TEXT NOT NULL REFERENCES execution_origins(id));
CREATE TABLE IF NOT EXISTS domain_history (
 origin TEXT NOT NULL, node TEXT NOT NULL, member TEXT NOT NULL, event TEXT NOT NULL, digest TEXT NOT NULL,
 PRIMARY KEY(origin,node,member,event));
CREATE TABLE IF NOT EXISTS domain_migrations (operation_id TEXT PRIMARY KEY, digest TEXT NOT NULL, receipt TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS source_authority (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), epoch INTEGER NOT NULL CHECK(epoch>=0), record TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS source_keys (
 public_key_sha256 TEXT PRIMARY KEY, epoch INTEGER NOT NULL UNIQUE CHECK(epoch>=0), certificate_sha256 TEXT NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS source_rotations (
 operation_id TEXT PRIMARY KEY, digest TEXT NOT NULL, proposer TEXT NOT NULL, command TEXT NOT NULL, receipt TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS review_deployment (singleton INTEGER PRIMARY KEY CHECK(singleton=1));
CREATE TABLE IF NOT EXISTS review_keys (epoch INTEGER PRIMARY KEY CHECK(epoch>=0), record TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS review_authority (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), epoch INTEGER NOT NULL CHECK(epoch>=0), record TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority_pending (
 operation_id TEXT PRIMARY KEY, digest TEXT NOT NULL, proposal TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority_review_requirements (
 operation_id TEXT PRIMARY KEY, digest TEXT NOT NULL, parent TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority_reviews (
 operation_id TEXT PRIMARY KEY REFERENCES authority_review_requirements(operation_id),
 digest TEXT NOT NULL, artifact_digest TEXT NOT NULL, record TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority_delta_reviews (
 operation_id TEXT NOT NULL REFERENCES authority_reviews(operation_id), reviewer_epoch INTEGER NOT NULL,
 source_epoch INTEGER NOT NULL, digest TEXT NOT NULL, record TEXT NOT NULL,
 PRIMARY KEY(operation_id,reviewer_epoch,source_epoch));
CREATE TABLE IF NOT EXISTS task_publications (
 family TEXT PRIMARY KEY REFERENCES tasks(family), operation_id TEXT NOT NULL, digest TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL,
 fence INTEGER NOT NULL, policy TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority_schema (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority_publications (
 operation_id TEXT PRIMARY KEY, digest TEXT NOT NULL, request TEXT NOT NULL, receipt TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS authority_review_heads (
 singleton INTEGER PRIMARY KEY CHECK(singleton=1), operation_id TEXT NOT NULL REFERENCES authority_publications(operation_id),
 digest TEXT NOT NULL, revision INTEGER NOT NULL, fence INTEGER NOT NULL, reviewer_epoch INTEGER NOT NULL,
 source_epoch INTEGER NOT NULL, issuer_record TEXT NOT NULL, review_record TEXT NOT NULL, delta_record TEXT NOT NULL);
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
 family TEXT NOT NULL, node TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('request','stream','provider')),
 reservations TEXT NOT NULL CHECK(json_valid(reservations) AND json_type(reservations)='object'), PRIMARY KEY(family,node));
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
