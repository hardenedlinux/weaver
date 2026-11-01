use weaver_governance::{
    OwnedSource, SourceExpectation, materialize_bound_source, materialize_source, root_source,
    source_lane,
};
#[path = "../unit/fixture.rs"]
mod fixture;
mod program;
#[path = "../support/replacement.rs"]
mod replacement;
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
        prop_assert, prop_assert_eq,
        test_runner::{Config, RngSeed, TestRunner},
    };
    let mut runner = TestRunner::new(Config {
        cases: 128,
        rng_seed: RngSeed::Fixed(293),
        failure_persistence: None,
        ..Config::default()
    });
    runner
        .run(
            &(
                0u64..=weaver_contracts::MAX_CREDITS,
                proptest::option::of(0u64..=weaver_contracts::MAX_CREDITS),
                proptest::collection::vec(proptest::char::any(), 1..32),
            ),
            |(fence, revision, chars)| {
                let mut sample = fixture::source();
                sample.publication.fence = fence;
                sample.publication.expected_revision = revision;
                sample.publication.policy =
                    format!("\0λ🙂{}", chars.into_iter().collect::<String>());
                let original = OwnedSource::from_source(sample.clone()).expect("original data");
                let root = root_source(&runtime, &original).expect("native input");
                drop(original);
                let owned = materialize_source(root).expect("native exact integer");
                prop_assert_eq!(owned.publication().fence, fence);
                prop_assert_eq!(owned.task().family.as_str(), "f");
                prop_assert!(owned.data() == &sample);
                Ok(())
            },
        )
        .expect("native SDK exact integer property");
    // Valid individual plans may exceed the aggregate native handoff bound.
    // Conversion must refuse and leave the same VM usable for the next input.
    let mut large = fixture::source();
    let mut plan = large.plans[0].clone();
    plan.body = format!(
        r#"{{"model":"model-a","stream":true,"messages":[{{"role":"user","content":"{}"}}],"max_completion_tokens":32}}"#,
        "x".repeat(256 * 1024)
    );
    let task = &mut large.tasks[0];
    task.nodes.clear();
    task.body_digests.clear();
    task.stream_contracts.clear();
    task.node_cost_bounds.clear();
    large.plans.clear();
    large.governance.open_nodes.clear();
    for index in 0..33 {
        let mut part = plan.clone();
        part.node = format!("part-{index}");
        task.nodes.push(part.node.clone());
        task.body_digests
            .insert(part.node.clone(), weaver_contracts::body_digest(&part.body));
        task.stream_contracts
            .insert(part.node.clone(), part.digest().expect("plan commitment"));
        task.node_cost_bounds
            .insert(part.node.clone(), part.ceiling);
        large.governance.open_nodes.push(part.node.clone());
        large.plans.push(part);
    }
    let large = OwnedSource::from_source(large).expect("internally valid oversized source");
    assert!(matches!(
        root_source(&runtime, &large),
        Err(weaver_governance::SourceError::Bound)
    ));
    drop(large);
    eprintln!("governance native input aggregate-bound refusal; same VM continues");
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
    for fault in 0..8 {
        assert!(
            materialize_source(rooted_source::publication(&runtime, &data, fault)).is_err(),
            "malformed scalar types, out-of-range integers, keys and unknown fields must refuse"
        );
    }

    let original = OwnedSource::from_source(data.clone()).expect("original input");
    for field in 0..11 {
        let changed = replacement::coherent(data.clone(), field, 1);
        assert!(OwnedSource::from_source(changed.clone()).is_ok());
        let root = rooted_source::source(&runtime, &changed);
        assert!(materialize_bound_source(root, SourceExpectation::capture(&original)).is_err());
    }
    // A coherent replacement can satisfy every local contract and still be
    // unauthorized. Exercise conversion and the independently retained original
    // together; refusals must leave this same VM usable for the legitimate root.
    runner
        .run(&(0usize..11, 1u64..1024), |(field, amount)| {
            let changed = replacement::coherent(data.clone(), field, amount);
            prop_assert!(changed != data);
            let candidate = OwnedSource::from_source(changed).expect("coherent replacement");
            let result = materialize_bound_source(
                root_source(&runtime, &candidate).expect("replacement root"),
                SourceExpectation::capture(&original),
            );
            prop_assert!(matches!(
                result,
                Err(weaver_governance::SourceError::Binding)
            ));
            let legitimate = materialize_bound_source(
                root_source(&runtime, &original).expect("legitimate root after refusal"),
                SourceExpectation::capture(&original),
            )
            .expect("refusal must not poison a valid subsequent conversion");
            prop_assert!(legitimate.source().data() == &data);
            Ok(())
        })
        .expect("native original-binding and refusal-recovery property");
    let expected = SourceExpectation::capture(&original);
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
    let bound = materialize_bound_source(result, expected).expect("original-bound materialization");
    let owned = bound.source();
    drop(input);
    assert_eq!(owned.task().family, "f");
    assert_eq!(owned.plans().len(), 2);

    // The caller receives only owned, original-bound data. All roots and the
    // non-Send SDK runtime remain on this owner thread through natural cleanup.
    let capacity = std::thread::available_parallelism().expect("host capacity");
    let (client, inbox) = source_lane(capacity);
    let lane_input = OwnedSource::from_source(data.clone()).expect("lane original");
    let caller = std::thread::spawn(move || {
        let executor = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("caller runtime");
        let result = executor.block_on(client.submit(lane_input).expect("admission"));
        client.close();
        result.expect("owned lane result")
    });
    inbox.run(|source| {
        let input = root_source(&runtime, source)?;
        let result = capture
            .call(&input)
            .into_result()
            .map_err(|_| weaver_governance::SourceError::Scheme)?;
        materialize_source(result)
    });
    let delivered = caller.join().expect("caller completed");

    drop(runtime);
    assert!(delivered.source().data() == &data);
    assert_eq!(owned.publication().operation_id, "source");
    assert_eq!(owned.plans()[0].body, data.plans[0].body);
}
