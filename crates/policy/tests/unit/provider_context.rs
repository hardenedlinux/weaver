// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use crate::ProviderCheck;
use crate::provider_context::ProviderContext;
use proptest::{
    arbitrary::any, prop_assert, prop_assert_eq, proptest, test_runner::Config as ProptestConfig,
};
#[path = "../../../contracts/benches/support/fixtures.rs"]
mod fixture;
#[path = "../support/provider_context.rs"]
mod oracle;

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]
    #[test]
    fn native_context_matches_json_without_retaining_mutable_domains(
        sequence in any::<u64>(), held in any::<u64>(), epoch in any::<u64>(),
        history in any::<u64>(), limit in any::<u64>(), text_value in ".{0,64}", include in any::<bool>()
    ) {
        let (task, plan)=fixture::task_plan(128,"https://provider.invalid/v1/chat/completions");
        let route=&plan.routes[0];
        let facts=plan.binding(&task).expect("valid fixture or matching context projection").expect("valid fixture or matching context projection");
        let native=ProviderContext::capture(&task,&plan,route,&facts).expect("valid fixture or matching context projection");
        let reference=oracle::JsonContext::capture(&task,&plan,route);
        let domains=weaver_contracts::DomainView { family:"f".into(),canonical_family:"f".into(),
            stamp:weaver_contracts::DomainStamp {task_key:text_value.clone(),origin:text_value.clone(),budget_root:text_value.clone(),history_root:text_value,
                budget_epoch:epoch,history_epoch:epoch},held,budget_limit:limit,history_count:history };
        let check=ProviderCheck {action:"emitProvider",sequence,format:"protobuf",domains:if include {Some(&domains)} else {None}};
        let actual=native.current(&check);
        let expected=reference.current(&check);
        prop_assert_eq!(actual.is_ok(),expected.is_ok());
        if let (Ok(actual),Ok(expected))=(actual,expected) {
            prop_assert_eq!(actual.to_json_value().expect("valid fixture or matching context projection"),expected.to_json_value().expect("valid fixture or matching context projection"));
        }
        let without=ProviderCheck {action:"emitProvider",sequence:0,format:"arrow",domains:None};
        prop_assert_eq!(native.current(&without).expect("valid fixture or matching context projection").to_json_value().expect("valid fixture or matching context projection"),reference.current(&without).expect("valid fixture or matching context projection").to_json_value().expect("valid fixture or matching context projection"));
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]
    #[test]
    fn fresh_policy_and_domain_facts_control_every_decision(
        sequence in 0u64..8, held in 0u64..16, limit in 0u64..16,
        epoch in 0u64..4, history in 0u64..8, arrow in any::<bool>(), moved in any::<bool>()
    ) {
        let (task,plan)=fixture::task_plan(128,"https://provider.invalid/v1/chat/completions");
        let binding=crate::bind_provider(&task,&plan,&plan.routes[0]).expect("valid fixture or matching context projection");
        let source="permit(principal,action,resource) when { context.sequence < 4 && context.format == \"protobuf\" && context.shared_held <= context.shared_limit && context.budget_epoch == 1 && context.history_epoch == 1 && context.history_count < 4 && context.budget_domain == \"budget\" };";
        let domains=weaver_contracts::DomainView {family:"f".into(),canonical_family:"f".into(),
            stamp:weaver_contracts::DomainStamp {task_key:"task".into(),origin:"origin".into(),budget_root:if moved {"moved".into()} else {"budget".into()},history_root:"history".into(),budget_epoch:epoch,history_epoch:epoch},held,budget_limit:limit,history_count:history};
        let check=|| ProviderCheck {action:"emitProvider",sequence,format:if arrow {"arrow"} else {"protobuf"},domains:Some(&domains)};
        let allowed=sequence<4 && !arrow && held<=limit && epoch==1 && history<4 && !moved;
        prop_assert_eq!(binding.authorize(source,check()).is_ok(),allowed);
        prop_assert!(binding.authorize("forbid(principal,action,resource);",check()).is_err());
        prop_assert_eq!(binding.authorize(source,check()).is_ok(),allowed);
        let missing_domains = ProviderCheck {domains:None,..check()};
        prop_assert!(binding.authorize(source,missing_domains).is_err(), "missing live domains must deny");
    }
}
