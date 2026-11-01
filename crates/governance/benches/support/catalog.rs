//! Warm local catalog lookup and bounded data delivery; no Gerbil or authority check.
use super::fixture;
use criterion::Criterion;
use weaver_contracts::{SourceAuthority, SourceIdentity};
use weaver_governance::{ApprovedProducer, OwnedSource, ProducerCatalog, source_lane};
pub fn catalog(c: &mut Criterion) {
    for size in [1, 64] {
        let authority = SourceAuthority {
            epoch: 1,
            identity: SourceIdentity {
                certificate_sha256: "1".repeat(64),
                public_key_sha256: "2".repeat(64),
                credential_sha256: "3".repeat(64),
            },
        };
        let entries = (0..size)
            .map(|index| {
                let mut data = fixture::source();
                let family = format!("f-{index}");
                data.governance.family = family.clone();
                data.tasks[0].family = family.clone();
                for plan in &mut data.plans {
                    plan.family = family.clone();
                    data.tasks[0]
                        .stream_contracts
                        .insert(plan.node.clone(), plan.digest().expect("commitment"));
                }
                ApprovedProducer::new(
                    format!("p-{index}"),
                    authority.clone(),
                    OwnedSource::from_source(data).expect("original"),
                )
                .expect("producer binding")
            })
            .collect();
        let catalog = ProducerCatalog::from_entries(entries).expect("catalog");
        let (source, inbox) =
            source_lane(std::thread::available_parallelism().expect("host budget"));
        let close = source.clone();
        let client = catalog.bind(source);
        let worker = std::thread::spawn(move || inbox.run(|source| Ok(source.clone())));
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .expect("caller runtime");
        let selected = format!("p-{}", size - 1);
        c.bench_function(
            &format!("governance/producer_catalog_roundtrip/{size}"),
            |b| {
                b.iter(|| {
                    let job = client
                        .submit(
                            std::hint::black_box(&selected),
                            std::hint::black_box(&authority),
                        )
                        .expect("selection");
                    assert!(runtime.block_on(job).is_ok());
                })
            },
        );
        close.close();
        worker.join().expect("owner drained");
    }
}
