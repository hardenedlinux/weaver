// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{
    ApprovedProducer, CatalogError, OwnedSource, ProducerCatalog, source_fixture as fixture,
    source_lane,
};
use std::num::NonZeroUsize;
use weaver_contracts::{SourceAuthority, SourceIdentity};
fn authority(epoch: u64) -> SourceAuthority {
    SourceAuthority {
        epoch,
        identity: SourceIdentity {
            certificate_sha256: "1".repeat(64),
            public_key_sha256: "2".repeat(64),
            credential_sha256: "3".repeat(64),
        },
    }
}
fn original(family: &str) -> OwnedSource {
    let mut data = fixture::source();
    data.governance.family = family.into();
    data.tasks[0].family = family.into();
    for plan in &mut data.plans {
        plan.family = family.into();
        data.tasks[0]
            .stream_contracts
            .insert(plan.node.clone(), plan.digest().expect("commitment"));
    }
    OwnedSource::from_source(data).expect("consistent original")
}
fn entry(name: &str, family: &str) -> ApprovedProducer {
    ApprovedProducer::new(name.into(), authority(1), original(family)).expect("approved binding")
}
#[test]
fn conflicting_names_families_and_publication_ids_cannot_form_a_catalog() {
    assert!(ProducerCatalog::from_entries(vec![]).is_err());
    assert!(ProducerCatalog::from_entries(vec![entry("a", "f"), entry("a", "g")]).is_err());
    assert!(ProducerCatalog::from_entries(vec![entry("a", "f"), entry("alias", "f")]).is_err());
    let mut changed = original("g").data().clone();
    changed.publication.fence += 1;
    let changed = ApprovedProducer::new(
        "b".into(),
        authority(1),
        OwnedSource::from_source(changed).expect("valid"),
    )
    .expect("binding");
    assert!(ProducerCatalog::from_entries(vec![entry("a", "f"), changed]).is_err());
    assert!(ProducerCatalog::from_entries(vec![entry("a", "f"), entry("b", "g")]).is_ok());
}
#[test]
fn selection_retains_catalog_original_after_callers_and_catalog_are_dropped() {
    let (source, inbox) = source_lane(NonZeroUsize::new(2).expect("capacity"));
    let close = source.clone();
    let catalog = ProducerCatalog::from_entries(vec![entry("approved", "f")])
        .expect("catalog")
        .bind(source);
    let job = catalog
        .submit("approved", &authority(1))
        .expect("registered source");
    drop(catalog);
    let worker = std::thread::spawn(move || inbox.run(|original| Ok(original.clone())));
    let runtime = tokio::runtime::Builder::new_current_thread()
        .build()
        .expect("runtime");
    let result = runtime.block_on(job).expect("original result");
    close.close();
    worker.join().expect("natural owner drain");
    assert_eq!(result.source().task().family, "f");
    assert_eq!(result.source().task().budget, 8);
}
#[test]
fn invalid_authority_and_entry_count_are_refused_before_installation() {
    let mut invalid = authority(1);
    invalid.identity.public_key_sha256 = "0".repeat(64);
    assert!(ApprovedProducer::new("approved".into(), invalid, original("f")).is_err());
    assert!(ApprovedProducer::new("".into(), authority(1), original("f")).is_err());
    let entries = (0..65)
        .map(|index| entry(&format!("p-{index}"), &format!("f-{index}")))
        .collect();
    assert!(ProducerCatalog::from_entries(entries).is_err());
}
#[test]
fn catalog_bounds_total_utf8_text_even_when_each_original_is_consistent() {
    let entries = (0..64)
        .map(|index| {
            let mut data = original(&format!("f-{index}")).data().clone();
            data.publication.policy = "λ".repeat(32768);
            data.publication.schema = "λ".repeat(32768);
            let original = OwnedSource::from_source(data).expect("individual typed record");
            ApprovedProducer::new(format!("p-{index}"), authority(1), original).expect("binding")
        })
        .collect();
    // Individual records satisfy structural bounds; no Cedar Allow is claimed.
    assert!(ProducerCatalog::from_entries(entries).is_err());
}
proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config {
        cases:128,rng_seed:proptest::test_runner::RngSeed::Fixed(293),..Default::default()
    })]
    #[test]
    fn changed_source_observations_and_fresh_names_cannot_select_original(
        field in 0u8..5,amount in 2u64..1024
    ) {
        let (source,inbox)=source_lane(NonZeroUsize::new(2).expect("capacity"));
        let close=source.clone();let client=ProducerCatalog::from_entries(vec![entry("approved","f")])
            .expect("catalog").bind(source);
        let mut observed=authority(1);
        match field {
            0=>observed.epoch=amount,
            1=>observed.identity.certificate_sha256="4".repeat(64),
            2=>observed.identity.public_key_sha256="5".repeat(64),
            3=>observed.identity.credential_sha256="6".repeat(64),
            _=>{},
        }
        let name=if field==4 {"new-producer"} else {"approved"};
        proptest::prop_assert!(matches!(client.submit(name,&observed),Err(CatalogError::Denied)));
        // Refusal did not consume capacity or invoke a producer.
        let job=client.submit("approved",&authority(1)).expect("original remains selectable");
        drop(job);close.close();drop(inbox);
    }
}
