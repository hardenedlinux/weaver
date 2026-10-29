use weaver_contracts::{Proposal, Task, body_digest};

#[test]
fn default_deny_forbid_and_evaluation_error_are_fail_closed() {
    let p = Proposal {
        family: "f".into(),
        node: "n".into(),
        profile: "p".into(),
        target: "t".into(),
        endpoint: "https://example.invalid/".into(),
        model: "m".into(),
        body: r#"{"model":"m"}"#.into(),
        ceiling: 1,
        revision: 0,
        fence: 0,
    };
    let task = Task {
        family: "f".into(),
        principal: "alice".into(),
        profile: "p".into(),
        nodes: vec!["n".into()],
        targets: vec!["t".into()],
        endpoints: [("t".into(), p.endpoint.clone())].into(),
        body_digests: [("n".into(), body_digest(&p.body))].into(),
        stream_contracts: Default::default(),
        node_cost_bounds: [("n".into(), 1)].into(),
        models: vec!["m".into()],
        budget: 1,
    };
    assert!(weaver_policy::authorize("", &task, &p).is_err());
    assert!(weaver_policy::authorize("permit(principal,action,resource);", &task, &p).is_ok());
    assert!(
        weaver_policy::authorize(
            "permit(principal,action,resource); forbid(principal,action,resource);",
            &task,
            &p
        )
        .is_err()
    );
    assert!(weaver_policy::authorize("permit(principal,action,resource); permit(principal,action,resource) when { context.missing };",&task,&p).is_err());
}
