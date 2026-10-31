use cedar_poo_runtime::ValidatedManifest;
use weaver_contracts::{AuthorityParent, Publication, PublicationReview, body_digest};

pub fn fixture(
    (mut change, mut review, mut evidence): (Publication, PublicationReview, serde_json::Value),
) -> (Publication, PublicationReview, String) {
    let manifest: ValidatedManifest =
        serde_json::from_value(evidence["manifest"].clone()).expect("manifest");
    let before = manifest
        .cases
        .iter()
        .find(|c| c.name == "published-public")
        .expect("original parent");
    let policy = before.policies.to_json_string().expect("parent PolicySet");
    change.expected_revision = Some(0);
    change.fence = 2;
    review.publication.digest = change.digest().expect("revision command");
    review.parent = Some(AuthorityParent {
        revision: 0,
        fence: 1,
        policy_digest: body_digest(&policy),
        schema_digest: Some(body_digest(&change.schema)),
    });
    evidence["predecessor"] =
        serde_json::json!({"case":"published-public","policy":policy,"schema":change.schema});
    review.artifact = evidence.to_string();
    (change, review, policy)
}
