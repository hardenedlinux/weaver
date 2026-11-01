use crate::{ProducerCatalog, source_fixture};
use proptest::{arbitrary::any, prop_assert_eq, proptest};
use serde_json::json;
fn configuration(name: &str, epoch: u64) -> serde_json::Value {
    let source = source_fixture::source();
    json!({"producers":[{"name":name,"authority":{"epoch":epoch,"identity":{"certificate_sha256":"1".repeat(64),"public_key_sha256":"2".repeat(64),"credential_sha256":"3".repeat(64)}},
    "original":{"governance":{"schema":source.governance.schema,"family":source.governance.family,"open_nodes":source.governance.open_nodes},"tasks":source.tasks,"plans":source.plans,"publication":source.publication}}]})
}
proptest! {
    #[test]
    fn configuration_cannot_alias_one_family(name in "[a-z]{1,32}", epoch in 0u64..=weaver_contracts::MAX_CREDITS, duplicate in any::<bool>()) {
        let mut data = configuration(&name,epoch);
        if duplicate {
            let mut alias=data["producers"][0].clone();
            alias["name"]=json!(format!("{name}-alias"));
            data["producers"].as_array_mut().expect("array").push(alias);
        }
        let bytes=serde_json::to_vec(&data).expect("data");
        prop_assert_eq!(ProducerCatalog::from_configuration(&bytes).is_ok(),!duplicate);
    }
}
#[test]
fn configuration_rejects_duplicate_keys_code_and_source_substitution_fields() {
    let data = configuration("approved", 0);
    let rows = &data["producers"];
    let duplicate = format!("{{\"producers\":{rows},\"producers\":{rows}}}");
    assert!(ProducerCatalog::from_configuration(duplicate.as_bytes()).is_err());
    for field in ["module", "source", "callback", "authority_override"] {
        let mut changed = data.clone();
        changed[field] = json!("untrusted");
        assert!(
            ProducerCatalog::from_configuration(&serde_json::to_vec(&changed).expect("data"))
                .is_err()
        );
    }
    assert!(ProducerCatalog::from_configuration(br#"{"producers":[]}"#).is_err());
}
