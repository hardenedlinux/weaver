use cedar_poo_runtime::{ValidatedManifest, render_policy_source};
use proptest::{prop_assert, proptest};
#[path = "../support/publication_replay.rs"]
mod source;
use source::{MANIFEST, fixture};

#[test]
fn actual_lean_produced_named_candidate_replays_under_the_existing_spec_pin() {
    let (change, review, _) = fixture();
    weaver_policy::validate_typed(&change.policy, &change.schema)
        .expect("native identified PolicySet");
    let observed = weaver_policy::verify_publication_replay(&change, &review)
        .expect("actual upstream receipts");
    assert_eq!(observed.publication, review.publication);
    assert_eq!(observed.artifact_digest, review.digest().expect("digest"));
    assert_eq!(
        observed.candidate_cases, 2,
        "four manifest cases are not four selected-candidate cases"
    );
}

#[test]
fn text_rendering_cannot_silently_replace_original_policy_ids() {
    let (mut change, mut review, _) = fixture();
    let manifest: ValidatedManifest =
        weaver_contracts::decode(MANIFEST.as_bytes()).expect("manifest");
    let case = manifest
        .cases
        .iter()
        .find(|c| c.name == "scoped-public")
        .expect("case");
    change.policy = render_policy_source(&case.policies).expect("upstream full text renderer");
    weaver_policy::validate_typed(&change.policy, &change.schema).expect("same executable body");
    review.publication.digest = change.digest().expect("new command");
    assert!(
        weaver_policy::verify_publication_replay(&change, &review).is_err(),
        "comments cannot retain native Policy ID"
    );
}

#[test]
fn duplicate_evidence_keys_and_unknown_approval_labels_are_refused() {
    let (change, mut review, mut evidence) = fixture();
    evidence["approved"] = true.into();
    review.artifact = evidence.to_string();
    assert!(weaver_policy::verify_publication_replay(&change, &review).is_err());
    let (_, mut review, _) = fixture();
    review.artifact = review.artifact.replacen(
        "\"candidate_case\":",
        "\"candidate_case\":\"forged\",\"candidate_case\":",
        1,
    );
    assert!(weaver_policy::verify_publication_replay(&change, &review).is_err());
}

proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(64))]
    #[test]
    fn recomputed_artifact_digest_cannot_hide_candidate_or_receipt_substitution(field in 0u8..8) {
        let (mut change,mut review,mut evidence)=fixture();
        match field {
            0=>evidence["receipts"][0]["schema_sha256"]="0".repeat(64).into(),
            1=>evidence["receipts"][0]["replay"]["policies_sha256"]="0".repeat(64).into(),
            2=>evidence["receipts"][0]["replay"]["decision"]="deny".into(),
            3=>evidence["candidate_case"]="published-public".into(),
            4=>{evidence["manifest"]["cases"][2]["policy_ids"]=serde_json::json!(["forged"]);},
            5=>{evidence["receipts"].as_array_mut().expect("receipts").pop();},
            6=>{change.schema="{}".into();review.publication.digest=change.digest().expect("rebound bytes");},
            _=>review.publication.operation_id="different-original".into(),
        }
        review.artifact=evidence.to_string();
        prop_assert!(weaver_policy::verify_publication_replay(&change,&review).is_err());
    }
}
