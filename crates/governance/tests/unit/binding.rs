use crate::source_fixture as fixture;
#[path = "../support/replacement.rs"]
mod replacement;
use crate::{BoundSource, OwnedSource, SourceExpectation};
use proptest::{
    prop_assert, proptest,
    test_runner::{Config, RngSeed},
};
fn original() -> OwnedSource {
    OwnedSource::from_source(fixture::source()).expect("original")
}
#[test]
fn binding_is_an_independent_snapshot_not_an_alias_or_permit() {
    fn send<T: Send + Sync>() {}
    send::<BoundSource>();
    let mut input = fixture::source();
    let admitted = OwnedSource::from_source(input.clone()).expect("source");
    let expected = SourceExpectation::capture(&admitted);
    input.tasks[0].budget += 1;
    assert!(
        expected
            .bind(OwnedSource::from_source(input).expect("coherent"))
            .is_err()
    );
    let bound = SourceExpectation::capture(&admitted)
        .bind(original())
        .expect("same source");
    drop(admitted);
    assert_eq!(bound.source().task().family, "f");
}
#[test]
fn immutable_original_sharing_survives_replacing_every_external_handle() {
    let mut admitted = original();
    let retained = admitted.clone();
    let expected = SourceExpectation::capture(&admitted);
    admitted = OwnedSource::from_source(replacement::coherent(fixture::source(), 2, 1))
        .expect("replacement");
    assert!(admitted.data() != retained.data());
    drop(admitted);
    assert!(expected.bind(retained).is_ok());
}
#[test]
fn rebuilding_the_expectation_from_the_candidate_is_an_unsafe_negative_control() {
    let candidate =
        OwnedSource::from_source(replacement::coherent(fixture::source(), 2, 1)).expect("coherent");
    assert!(
        SourceExpectation::capture(&original())
            .bind(candidate)
            .is_err()
    );
    let candidate =
        OwnedSource::from_source(replacement::coherent(fixture::source(), 2, 1)).expect("coherent");
    // This passes content equality while failing the protocol's original-input
    // premise. Native conversion or a caller-created label cannot supply it.
    assert!(
        SourceExpectation::capture(&candidate)
            .bind(candidate)
            .is_ok()
    );
}
proptest! {
    #![proptest_config(Config { cases: 128, rng_seed: RngSeed::Fixed(293), ..Config::default() })]
    #[test]
    fn coherent_replacements_cannot_change_original_content(field in 0usize..11, amount in 1u64..1024) {
        let input = original();
        let expected = SourceExpectation::capture(&input);
        let changed = replacement::coherent(fixture::source(),field,amount);
        let candidate = OwnedSource::from_source(changed);
        prop_assert!(candidate.is_ok(), "negative control must remain internally valid");
        prop_assert!(expected.bind(candidate.expect("coherent")).is_err());
        prop_assert!(SourceExpectation::capture(&input).bind(original()).is_ok());
    }
}
