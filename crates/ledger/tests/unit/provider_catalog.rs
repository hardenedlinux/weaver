// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::ProviderCatalogProjection;
use weaver_contracts::ProviderCatalog;

#[test]
fn inspection_reuses_only_verified_catalog_bytes() {
    let catalog = ProviderCatalog {
        parent: String::new(),
        entries: Default::default(),
    };
    let digest = catalog.digest().expect("catalog digest");
    let record =
        String::from_utf8(catalog.record().expect("catalog record")).expect("catalog UTF-8");
    let mut projection = ProviderCatalogProjection::default();
    let project = |projection: &mut ProviderCatalogProjection, bytes: String| {
        projection.project(digest.clone(), bytes)
    };

    project(&mut projection, record.clone()).expect("verify first snapshot");
    assert_eq!(
        project(&mut projection, record.clone())
            .expect("reuse exact snapshot")
            .1,
        record.as_bytes(),
    );
    assert!(project(&mut projection, String::from("{}")).is_err());
    assert!(
        project(
            &mut projection,
            record.replace("\"parent\":\"\"", "\"parent\":\"other\"")
        )
        .is_err()
    );
    assert_eq!(
        project(&mut projection, format!(" {record}\n"))
            .expect("normalize older record")
            .1,
        record.as_bytes(),
    );
    assert!(projection.canonical.is_none());
    assert!(
        projection
            .project(String::from("wrong-version"), record)
            .is_err()
    );
}
