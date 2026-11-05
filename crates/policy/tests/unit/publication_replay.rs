// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use cedar_poo_runtime::{ValidatedManifest, render_policy_source};
use proptest::{prop_assert, proptest};
#[path = "../support/publication_revision.rs"]
mod revision;
#[path = "../support/publication_replay.rs"]
mod source;
use source::{MANIFEST, fixture};

#[test]
fn actual_parent_and_candidate_are_both_bound_to_the_captured_authority() {
    let (change, review, policy) = revision::fixture(fixture());
    let parent = review.parent.as_ref().expect("fixture authority");
    assert_eq!(parent.policy_digest, weaver_contracts::body_digest(&policy));
    let check = weaver_policy::verify_publication_replay(&change, &review, Some(parent))
        .expect("actual pair");
    assert_eq!(check.parent.as_ref(), Some(parent));
    assert_eq!((check.parent_cases, check.candidate_cases), (2, 2));
}

proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(64))]
    #[test]
    fn replay_cannot_substitute_the_captured_predecessor(field in 0u8..8, padding in 1usize..17) {
        let (mut change, mut review, policy) = revision::fixture(fixture());
        let captured = review.parent.clone();
        let mut evidence: serde_json::Value = weaver_contracts::decode(review.artifact.as_bytes()).expect("evidence");
        match field {
            0 => evidence["predecessor"] = serde_json::Value::Null,
            1 => evidence["predecessor"]["policy"] = format!("{policy}{}", " ".repeat(padding)).into(),
            2 => evidence["predecessor"]["schema"] = "{}".into(),
            3 => evidence["predecessor"]["case"] = "scoped-public".into(),
            4 => {review.parent.as_mut().expect("parent").fence += 1;},
            5 => {change.expected_revision = None; review.publication.digest = change.digest().expect("command");},
            6 => evidence["predecessor"]["approved"] = true.into(),
            _ => review.parent = None,
        }
        review.artifact = evidence.to_string();
        prop_assert!(weaver_policy::verify_publication_replay(&change, &review, captured.as_ref()).is_err());
    }
}

#[test]
fn known_genesis_cannot_be_selected_for_an_existing_parent_or_assert_a_predecessor() {
    let (change, review, _) = revision::fixture(fixture());
    assert!(weaver_policy::verify_publication_replay(&change, &review, None).is_err());
    let (change, mut genesis, _) = fixture();
    let mut evidence: serde_json::Value =
        weaver_contracts::decode(review.artifact.as_bytes()).expect("pair");
    evidence["candidate_case"] = "scoped-public".into();
    genesis.artifact = evidence.to_string();
    assert!(weaver_policy::verify_publication_replay(&change, &genesis, None).is_err());
}

#[test]
fn actual_lean_produced_named_candidate_replays_under_the_existing_spec_pin() {
    let (change, review, _) = fixture();
    weaver_policy::validate_typed(&change.policy, &change.schema)
        .expect("native identified PolicySet");
    let observed = weaver_policy::verify_publication_replay(&change, &review, None)
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
        weaver_policy::verify_publication_replay(&change, &review, None).is_err(),
        "comments cannot retain native Policy ID"
    );
}

#[test]
fn duplicate_evidence_keys_and_unknown_approval_labels_are_refused() {
    let (change, mut review, mut evidence) = fixture();
    evidence["approved"] = true.into();
    review.artifact = evidence.to_string();
    assert!(weaver_policy::verify_publication_replay(&change, &review, None).is_err());
    let (_, mut review, _) = fixture();
    review.artifact = review.artifact.replacen(
        "\"candidate_case\":",
        "\"candidate_case\":\"forged\",\"candidate_case\":",
        1,
    );
    assert!(weaver_policy::verify_publication_replay(&change, &review, None).is_err());
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
        prop_assert!(weaver_policy::verify_publication_replay(&change,&review,None).is_err());
    }
}
