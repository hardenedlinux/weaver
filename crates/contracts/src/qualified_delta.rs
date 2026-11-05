// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Deployment-qualified SPEC outputs. These data types grant no authority.
use serde::{Deserialize, Serialize};

/// Complete output of the independently qualified SPEC analyzer.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QualifiedDeltaCatalog {
    pub engine: String,
    pub qualification: String,
    pub entries: Vec<QualifiedDeltaEntry>,
}
/// Exact analyzed Policy/schema bytes and schema-world solver outcome.
/// A solver report is distinct from a kernel UNSAT certificate.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QualifiedDeltaEntry {
    pub name: String,
    pub before_policy: String,
    pub after_policy: String,
    pub schema: String,
    pub epoch: u64,
    pub environments: u64,
    pub gains: u64,
    pub losses: u64,
    pub classification: String,
}
