#[path = "../../benches/support/fixtures.rs"]
mod fixtures;

use proptest::{arbitrary::any, prop_assert_eq, proptest, test_runner::Config};

#[test]
fn competing_provider_limits_are_rejected_even_when_the_preferred_one_is_bounded() {
    let (_, mut plan) = fixtures::task_plan(8, "https://provider.invalid/v1/chat/completions");
    let mut body: serde_json::Value = serde_json::from_str(&plan.body).expect("fixture");
    body["max_tokens"] = serde_json::json!(1000000);
    plan.body = serde_json::to_string(&body).expect("request");
    assert!(plan.validate().is_err(), "ambiguous provider cap admitted");
}

#[test]
fn provider_cap_must_be_a_positive_bounded_integer() {
    let (_, original) = fixtures::task_plan(8, "https://provider.invalid/v1/chat/completions");
    for value in [
        serde_json::json!(0),
        serde_json::json!(-1),
        serde_json::json!(4097),
        serde_json::json!(32.5),
        serde_json::json!("32"),
        serde_json::Value::Null,
    ] {
        let mut plan = original.clone();
        let mut body: serde_json::Value = serde_json::from_str(&plan.body).expect("fixture");
        body["max_completion_tokens"] = value;
        plan.body = serde_json::to_string(&body).expect("request");
        assert!(plan.validate().is_err(), "invalid provider cap admitted");
    }
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn exactly_one_provider_cap_is_bounded(modern in any::<bool>(), legacy in any::<bool>(), tokens in 0u64..8193) {
        let (_, mut plan) = fixtures::task_plan(8, "https://provider.invalid/v1/chat/completions");
        let mut body: serde_json::Value = serde_json::from_str(&plan.body).expect("fixture");
        body.as_object_mut().expect("object").remove("max_completion_tokens");
        if modern { body["max_completion_tokens"] = serde_json::json!(tokens); }
        if legacy { body["max_tokens"] = serde_json::json!(tokens); }
        plan.body = serde_json::to_string(&body).expect("request");
        prop_assert_eq!(plan.validate().is_ok(), modern != legacy && (1..=4096).contains(&tokens));
    }
}
