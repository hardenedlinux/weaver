//! Coherent but unauthorized replacement fixtures, never a new semantic engine.
use weaver_governance::SourceData;
pub fn coherent(mut data: SourceData, field: usize, amount: u64) -> SourceData {
    match field {
        0 => data.tasks[0].principal = "replacement-agent".into(),
        1 => data.tasks[0].budget += amount,
        2 => {
            data.governance.family = "replacement-family".into();
            data.tasks[0].family = data.governance.family.clone();
            for plan in &mut data.plans {
                plan.family = data.governance.family.clone();
            }
        }
        3 => data.publication.operation_id = format!("replacement-{amount}"),
        4 => data.publication.policy = "permit(principal,action,resource);".into(),
        5 => data.publication.schema = "{}".into(),
        6 => {
            for plan in &mut data.plans {
                plan.body = plan
                    .body
                    .replace("\"content\":\"", "\"content\":\"changed-");
            }
        }
        7 => {
            let endpoint = "https://replacement.invalid/v1/chat/completions";
            data.tasks[0]
                .endpoints
                .insert("primary".into(), endpoint.into());
            for plan in &mut data.plans {
                plan.routes[0].endpoint = endpoint.into();
            }
        }
        8 => data.plans.reverse(),
        9 => data.publication.expected_revision = Some(amount),
        _ => data.publication.fence += amount,
    }
    // Keep task/plan commitments valid: rejection must come from the independent
    // original binding, not an accidentally malformed body/profile/plan.
    for plan in &data.plans {
        data.tasks[0]
            .body_digests
            .insert(plan.node.clone(), weaver_contracts::body_digest(&plan.body));
        data.tasks[0]
            .stream_contracts
            .insert(plan.node.clone(), plan.digest().expect("replacement plan"));
    }
    data
}
