use weaver_governance::materialize_source;
#[path = "../../benches/support/fixture.rs"]
mod fixture;
mod program;
mod rooted_source;

#[test]
fn actual_aa_capture_materializes_owned_data_before_vm_cleanup() {
    assert_eq!(weaver_policy_ffi::weaver_policy_abi_v1(), 0x0001_0000);
    let runtime = program::initialize();
    eprintln!(
        "governance VM active_processors={}",
        runtime.active_processors().expect("processors")
    );
    let capture = program::capture(&runtime);
    // One runtime owns the whole framework run; no repeated VM initialization.
    use proptest::{
        prop_assert_eq,
        test_runner::{Config, RngSeed, TestRunner},
    };
    let mut runner = TestRunner::new(Config {
        cases: 128,
        rng_seed: RngSeed::Fixed(293),
        failure_persistence: None,
        ..Config::default()
    });
    runner
        .run(&(0u64..=weaver_contracts::MAX_CREDITS), |fence| {
            let mut sample = fixture::source();
            sample.publication.fence = fence;
            let root = rooted_source::source(&runtime, &sample);
            let owned = materialize_source(root).expect("native exact integer");
            prop_assert_eq!(owned.publication().fence, fence);
            prop_assert_eq!(owned.task().family.as_str(), "f");
            Ok(())
        })
        .expect("native SDK exact integer property");
    for fence in [0, (1u64 << 53) + 1, weaver_contracts::MAX_CREDITS] {
        let mut sample = fixture::source();
        sample.publication.fence = fence;
        assert_eq!(
            materialize_source(rooted_source::source(&runtime, &sample))
                .expect("boundary integer")
                .publication()
                .fence,
            fence
        );
    }
    let blob = runtime.string_from_utf8("{}").expect("blob").into_object();
    assert!(materialize_source(blob).is_err());
    let boolean = runtime
        .scalar_object(gerbil_scheme::SchemeScalar::Boolean(false))
        .expect("false");
    assert!(materialize_source(boolean).is_err());
    let data = fixture::source();
    for fault in 0..5 {
        assert!(
            materialize_source(rooted_source::publication(&runtime, &data, fault)).is_err(),
            "false/nil/float, string field keys and unknown fields must refuse"
        );
    }

    let input = rooted_source::source(&runtime, &data);
    let result = capture
        .call(&input)
        .into_result()
        .expect("actual AA capture");
    if result.as_ref().kind().expect("result kind") == gerbil_scheme::ObjectKind::String {
        panic!(
            "AA test fixture refused: {}",
            result
                .into_string()
                .expect("diagnostic")
                .to_string()
                .into_result()
                .expect("diagnostic copy")
        );
    }
    let owned = materialize_source(result).expect("owned materialization");
    drop(input);
    assert_eq!(owned.task().family, "f");
    assert_eq!(owned.plans().len(), 2);

    drop(runtime);
    assert_eq!(owned.publication().operation_id, "source");
    assert_eq!(owned.plans()[0].body, data.plans[0].body);
}
