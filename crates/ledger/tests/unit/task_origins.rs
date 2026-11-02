use super::{
    fixtures::{POLICY, proposal, task},
    source_authority::{identity, rotation},
};
use proptest::{prop_assert, prop_assert_eq, prop_assume, proptest, test_runner::Config};
use weaver_contracts::{DomainBinding, TaskAdmission};
use weaver_ledger::Ledger;

fn binding() -> DomainBinding {
    DomainBinding {
        origin: "original-origin".into(),
        budget: "shared".into(),
        history: "history".into(),
        budget_limit: 8,
    }
}
fn command() -> TaskAdmission {
    TaskAdmission {
        task_key: "source-task".into(),
        operation_id: "admit-task".into(),
        expected_source_epoch: 0,
    }
}

#[test]
fn source_rotation_cannot_reallocate_task_and_lost_reply_recovers_original_commit() {
    let d = tempfile::tempdir().expect("directory");
    let path = d.path().join("origin.db");
    let mut l = Ledger::open(&path).expect("ledger");
    let receipt = l
        .with_authenticated_source(&identity(0), |l| {
            l.publish(None, POLICY, 1)?;
            l.register_original_task(&task(), &binding(), &command(), None)
        })
        .expect("original commit");
    l.enqueue(&proposal(0, 4)).expect("reserve");
    let permit = l.consume("family", "n0").expect("consume");
    l.rotate_source_authority(&identity(0), &rotation(0))
        .expect("source switch");
    assert!(
        l.with_authenticated_source(&identity(0), |l| l.register_original_task(
            &task(),
            &binding(),
            &command(),
            None
        ))
        .is_err()
    );
    let mut next = command();
    next.operation_id = "late-worker".into();
    assert!(
        l.with_authenticated_source(&identity(1), |l| l.register_original_task(
            &task(),
            &binding(),
            &next,
            None
        ))
        .is_err()
    );
    next.expected_source_epoch = 1;
    let mut renamed = task();
    renamed.family = "new-family".into();
    let mut other = binding();
    other.origin = "new-origin".into();
    assert!(
        l.with_authenticated_source(&identity(1), |l| l
            .register_original_task(&renamed, &other, &next, None))
            .is_err()
    );
    next.task_key = "new-key".into();
    assert!(
        l.with_authenticated_source(&identity(1), |l| l.register_original_task(
            &task(),
            &binding(),
            &next,
            None
        ))
        .is_err()
    );
    drop(l);
    let mut recovered = Ledger::open(&path).expect("restart");
    let replay = recovered
        .with_authenticated_source(&identity(1), |l| {
            l.register_original_task(&task(), &binding(), &command(), None)
        })
        .expect("historical decision");
    assert_eq!(replay, receipt);
    assert!(
        recovered
            .dispatch(permit, |_| panic!("old worker sent"))
            .is_err()
    );
    assert!(recovered.consume("family", "n0").is_err());
    assert_eq!(recovered.execution_domains("family").expect("hold").held, 4);
}

#[test]
fn missing_registration_cannot_be_reconstructed_or_authorize_final_send() {
    let d = tempfile::tempdir().expect("directory");
    let path = d.path().join("partial.db");
    let mut l = super::fixtures::initialized(&path);
    l.enqueue(&proposal(0, 4)).expect("reserve");
    let permit = l.consume("family", "n0").expect("consume");
    let fault = weaver_ledger::persistence::Session::open(&path).expect("fault writer");
    weaver_ledger::persistence::exec(&fault, "DELETE FROM original_tasks", ())
        .expect("partial snapshot");
    assert!(
        l.dispatch(permit, |_| panic!("unbound original sent"))
            .is_err()
    );
    assert!(l.register_task(&task()).is_err());
    assert_eq!(l.held("family").expect("unknown held"), 4);
}

proptest! {
    #![proptest_config(Config::with_cases(24))]
    #[test]
    fn renamed_task_origin_and_attempt_cannot_reset_original_exposure(family in any_bool(),origin in any_bool(),key in any_bool()) {
        // At least one authoritative identity must remain bound to the original.
        // Relabeling every source identity is the explicit issuer-trust negative
        // control below, not a claim of semantic duplicate detection.
        prop_assume!(!(family && origin && key));
        let d=tempfile::tempdir().expect("directory");let mut l=Ledger::open(d.path().join("property.db")).expect("ledger");
        l.publish(None,POLICY,1).expect("policy");let original=l.register_original_task(&task(),&binding(),&command(),None).expect("admission");
        l.enqueue(&proposal(0,4)).expect("reserve");let _permit=l.consume("family","n0").expect("unknown");
        let mut t=task();let mut b=binding();let mut a=command();a.operation_id="new-attempt".into();
        if family {t.family="replacement-family".into();}
        if origin {b.origin="replacement-origin".into();}
        if key {a.task_key="replacement-key".into();}
        let result=l.register_original_task(&t,&b,&a,None);
        prop_assert_eq!(result.is_ok(),!family && !origin && !key);
        prop_assert_eq!(l.register_original_task(&task(),&binding(),&command(),None).expect("replay"),original);
        prop_assert!(l.consume("family","n0").is_err());
        prop_assert_eq!(l.execution_domains("family").expect("retained").held,4);
    }
}
fn any_bool() -> proptest::bool::Any {
    proptest::bool::ANY
}

#[test]
fn trusted_issuer_relabeling_every_identity_is_outside_local_deduplication() {
    let d = tempfile::tempdir().expect("directory");
    let mut l = Ledger::open(d.path().join("issuer.db")).expect("ledger");
    l.register_original_task(&task(), &binding(), &command(), None)
        .expect("original");
    let mut t = task();
    t.family = "new-source-family".into();
    let mut b = binding();
    b.origin = "new-source-origin".into();
    let mut a = command();
    a.task_key = "new-source-task".into();
    a.operation_id = "new-source-command".into();
    l.register_original_task(&t, &b, &a, None)
        .expect("genuine source may admit identical independent work");
    assert_eq!(
        l.execution_domains(&t.family)
            .expect("same shared constraints")
            .stamp
            .budget_root,
        "shared"
    );
}
