// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

/// Public fingerprints for source-boundary tests and benchmarks, not credentials.
pub fn source_identity(index: u64) -> weaver_contracts::SourceIdentity {
    weaver_contracts::SourceIdentity {
        certificate_sha256: weaver_contracts::body_digest(&format!("source-certificate-{index}")),
        public_key_sha256: weaver_contracts::body_digest(&format!("source-SPKI-{index}")),
        credential_sha256: weaver_contracts::body_digest("source-role"),
    }
}
