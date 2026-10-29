use super::fixtures::{POLICY, initialized, proposal, task};
use weaver_contracts::Outcome;
use weaver_ledger::Ledger;

#[test]
fn lost_enqueue_reply_recovers_same_hold_and_rejects_changed_wire() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("ledger.db");
    let mut ledger = initialized(&path);
    let p = proposal(0, 7);
    let first = ledger.enqueue(&p).expect("queue");
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("reopen");
    let recovered = ledger.enqueue(&p).expect("replay");
    assert_eq!(first.digest, recovered.digest);
    assert_eq!(ledger.held("family").expect("held"), 7);
    let mut changed = p.clone();
    changed.ceiling = 8;
    assert!(ledger.enqueue(&changed).is_err());
}

#[test]
fn crash_after_consumption_never_reopens_or_refunds() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("ledger.db");
    let mut ledger = initialized(&path);
    ledger.enqueue(&proposal(0, 7)).expect("queue");
    let permit = ledger.consume("family", "n0").expect("consume");
    drop(permit);
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("reopen");
    assert!(ledger.consume("family", "n0").is_err());
    assert_eq!(
        ledger
            .lookup("family", "n0")
            .expect("lookup")
            .expect("receipt")
            .outcome,
        Outcome::Unknown
    );
    assert_eq!(ledger.held("family").expect("held"), 7);
}

#[test]
fn publication_between_consume_and_send_closes_old_permit() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("ledger.db");
    let mut ledger = initialized(&path);
    ledger.enqueue(&proposal(0, 5)).expect("queue");
    let permit = ledger.consume("family", "n0").expect("consume");
    ledger.publish(Some(0), POLICY, 2).expect("advance");
    let mut calls = 0;
    assert!(
        ledger
            .dispatch(permit, |_| {
                calls += 1;
            })
            .is_err()
    );
    assert_eq!(calls, 0);
    assert_eq!(ledger.held("family").expect("held"), 5);
}

#[test]
fn token_cannot_move_to_a_second_ledger_handle() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("ledger.db");
    let mut first = initialized(&path);
    first.enqueue(&proposal(0, 5)).expect("queue");
    let permit = first.consume("family", "n0").expect("consume");
    let mut second = Ledger::open(&path).expect("second");
    let mut calls = 0;
    assert!(
        second
            .dispatch(permit, |_| {
                calls += 1;
            })
            .is_err()
    );
    assert_eq!(calls, 0);
}

#[test]
fn original_task_body_and_profile_cannot_be_replaced() {
    let temp = tempfile::tempdir().expect("temp");
    let mut ledger = initialized(&temp.path().join("ledger.db"));
    let mut original = task();
    original.budget = 100;
    assert!(ledger.register_task(&original).is_err());
    let mut p = proposal(0, 5);
    p.body = r#"{"model":"model-a","messages":["forged"]}"#.into();
    assert!(ledger.enqueue(&p).is_err());
    p = proposal(0, 5);
    p.endpoint = "https://attacker.invalid/".into();
    assert!(ledger.enqueue(&p).is_err());
    p = proposal(0, 5);
    p.profile = "forged".into();
    assert!(ledger.enqueue(&p).is_err());
    assert_eq!(ledger.held("family").expect("held"), 0);
}

#[test]
fn authored_ceiling_cannot_underreserve_the_original_wire_cost() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("cost.db");
    let mut ledger = Ledger::open(path).expect("open");
    ledger.publish(None, POLICY, 1).expect("publish");
    let mut original = task();
    original.node_cost_bounds.insert("n0".into(), 7);
    ledger.register_task(&original).expect("register");
    assert!(ledger.enqueue(&proposal(0, 6)).is_err());
    assert_eq!(ledger.held("family").expect("held"), 0);
    ledger.enqueue(&proposal(0, 7)).expect("sufficient hold");
}
