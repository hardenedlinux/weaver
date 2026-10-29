#[path = "../../../../dev/benchmarks/contracts.rs"]
mod fixtures;
#[test]
fn unregistered_cap_alias_must_not_pass_the_request_contract() {
    let (_,mut plan)=fixtures::task_plan(8,"https://provider.invalid/v1/chat/completions");
    let mut body:serde_json::Value=serde_json::from_str(&plan.body).expect("body");
    body["max_output_tokens"]=serde_json::json!(1000000);
    plan.body=serde_json::to_string(&body).expect("request");
    assert!(plan.validate().is_err(),"unregistered cap alias admitted by the original request checker");
}
