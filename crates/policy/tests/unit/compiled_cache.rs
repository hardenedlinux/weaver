// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

#[test]
fn exact_source_cache_is_bounded_and_never_caches_permission() {
    use weaver_contracts::{Proposal, Task, body_digest};
    let p = Proposal {
        family: "f".into(),
        node: "n".into(),
        profile: "p".into(),
        target: "t".into(),
        endpoint: "https://provider.invalid/".into(),
        model: "m".into(),
        body: "{\"model\":\"m\"}".into(),
        ceiling: 1,
        revision: 0,
        fence: 1,
    };
    let task = Task {
        provider_profile: None,
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
    let allow = "permit(principal,action,resource);";
    let deny = "forbid(principal,action,resource);";
    for _ in 0..16 {
        assert!(weaver_policy::authorize(allow, &task, &p).is_ok());
        assert!(weaver_policy::authorize(deny, &task, &p).is_err());
    }
    for number in 0..20 {
        let source =
            format!("permit(principal,action,resource) when {{ context.revision == {number} }};");
        assert_eq!(
            weaver_policy::authorize(&source, &task, &p).is_ok(),
            number == 0
        );
    }
    let mut changed = p.clone();
    changed.revision = 1;
    let same_source = "permit(principal,action,resource) when { context.revision == 0 };";
    assert!(weaver_policy::authorize(same_source, &task, &p).is_ok());
    assert!(weaver_policy::authorize(same_source, &task, &changed).is_err());
}
