// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::observe;
use tonic::Request;

#[test]
fn direct_ingress_rejects_forged_relay_evidence_before_credential_use() {
    let mut request = Request::new(());
    request.metadata_mut().insert(
        "weaver-provider-oauth-ingress-cert",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            .parse()
            .expect("metadata"),
    );
    assert_eq!(
        observe(true, false, &request)
            .err()
            .expect("relay evidence refused")
            .code(),
        tonic::Code::Unauthenticated
    );
    assert_eq!(
        observe(false, false, &request)
            .err()
            .expect("disabled profile refused")
            .code(),
        tonic::Code::FailedPrecondition
    );
}
