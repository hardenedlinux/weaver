use weaver_contracts::{Proposal, Task, body_digest};
use weaver_ledger::Ledger;

pub const POLICY: &str = r#"permit(principal == Weaver::Principal::"alice", action == Weaver::Action::"invoke", resource == Weaver::Target::"primary");"#;

pub fn task() -> Task {
    let body = body();
    Task {
        provider_profile: None,
        family: "family".into(),
        principal: "alice".into(),
        profile: "profile".into(),
        nodes: (0..8).map(|i| format!("n{i}")).collect(),
        targets: vec!["primary".into()],
        endpoints: [(
            "primary".into(),
            "https://example.invalid/v1/chat/completions".into(),
        )]
        .into(),
        body_digests: (0..8)
            .map(|i| (format!("n{i}"), body_digest(&body)))
            .collect(),
        stream_contracts: Default::default(),
        node_cost_bounds: (0..8).map(|i| (format!("n{i}"), 1)).collect(),
        models: vec!["model-a".into()],
        budget: 20,
    }
}
pub fn body() -> String {
    r#"{"model":"model-a","messages":[],"stream":false}"#.into()
}
pub fn proposal(node: u8, ceiling: u64) -> Proposal {
    Proposal {
        family: "family".into(),
        node: format!("n{node}"),
        profile: "profile".into(),
        target: "primary".into(),
        endpoint: "https://example.invalid/v1/chat/completions".into(),
        model: "model-a".into(),
        body: body(),
        ceiling,
        revision: 0,
        fence: 1,
    }
}
pub fn initialized(path: &std::path::Path) -> Ledger {
    let mut ledger = Ledger::open(path).expect("open");
    ledger.publish(None, POLICY, 1).expect("publish");
    ledger.register_task(&task()).expect("register");
    ledger
}
