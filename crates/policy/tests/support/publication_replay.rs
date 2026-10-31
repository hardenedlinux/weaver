use cedar_poo_runtime::{ValidatedManifest, replay_validated_manifest};
use serde_json::Value;
use weaver_contracts::{Publication, PublicationKey, PublicationReview};
pub const MANIFEST: &str =
    include_str!("../../../../prod/policies/review/namespaced-enum-validated.json");
pub fn fixture() -> (Publication, PublicationReview, Value) {
    let manifest: ValidatedManifest =
        weaver_contracts::decode(MANIFEST.as_bytes()).expect("upstream manifest");
    let receipts = replay_validated_manifest(&manifest).expect("actual fixed SPEC replay");
    let case = manifest
        .cases
        .iter()
        .find(|c| c.name == "scoped-public")
        .expect("candidate");
    let change = Publication {
        operation_id: "reviewed-candidate".into(),
        expected_revision: None,
        fence: 1,
        policy: case
            .policies
            .to_json_string()
            .expect("identified PolicySet"),
        schema: serde_json::to_string(&manifest.schema).expect("schema"),
    };
    let evidence = serde_json::json!({"manifest":serde_json::from_str::<Value>(MANIFEST).expect("wire"),"receipts":receipts,"candidate_case":"scoped-public"});
    let review = PublicationReview {
        publication: PublicationKey {
            operation_id: change.operation_id.clone(),
            digest: change.digest().expect("key"),
        },
        parent: None,
        artifact: evidence.to_string(),
    };
    (change, review, evidence)
}
