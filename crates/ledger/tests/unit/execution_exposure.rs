use super::{fixtures, stream_properties};
use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use weaver_contracts::{MessageRule, StreamContract, StreamMessage, WriteObservation};
use weaver_ledger::{Ledger, StreamClaim};

fn corrupt(path: &std::path::Path, stream: bool, fault: u8) {
    let connection = rusqlite::Connection::open(path).expect("fault writer");
    let sql = match (stream, fault) {
        (_, 0) => "DELETE FROM execution_claims",
        (false, 1) => "UPDATE execution_claims SET kind='stream'",
        (true, 1) => "UPDATE execution_claims SET kind='request'",
        (false, 2) => "UPDATE operations SET reserved=1 WHERE node='n0'",
        (true, 2) => "UPDATE stream_messages SET reserved=1 WHERE message='m0'",
        (_, 3) => "UPDATE tasks SET held=4",
        (false, 5) => "UPDATE tasks SET held=held+1",
        (true, 5) => "DELETE FROM stream_messages WHERE message='m1'",
        _ => "UPDATE tasks SET budget=budget+1",
    };
    connection
        .execute(sql, [])
        .expect("inconsistent recovery image");
}

#[test]
fn restart_never_backfills_request_claims_from_operations() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("restart.db");
    let mut ledger = fixtures::initialized(&path);
    ledger
        .enqueue(&fixtures::proposal(0, 4))
        .expect("reservation");
    corrupt(&path, false, 0);
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    let connection = rusqlite::Connection::open(&path).expect("observe");
    let claims: i64 = connection
        .query_row("SELECT COUNT(*) FROM execution_claims", [], |row| {
            row.get(0)
        })
        .expect("claims");
    assert_eq!(claims, 0);
    assert!(ledger.consume("family", "n0").is_err());
    assert_eq!(ledger.held("family").expect("hold"), 4);
    assert!(
        ledger
            .lookup("family", "n0")
            .expect("observation")
            .is_some()
    );
}

#[test]
fn orphaned_request_claim_cannot_admit_a_replacement_operation() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("orphaned.db");
    let mut ledger = fixtures::initialized(&path);
    let proposal = fixtures::proposal(0, 4);
    ledger.enqueue(&proposal).expect("original reservation");
    let permit = ledger
        .consume("family", "n0")
        .expect("original consumption");
    drop(permit);
    let connection = rusqlite::Connection::open(&path).expect("fault writer");
    connection
        .execute("DELETE FROM operations", [])
        .expect("lost projection");
    drop(connection);
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert!(ledger.enqueue(&proposal).is_err());
    assert_eq!(ledger.held("family").expect("unknown hold"), 4);
}

#[test]
fn next_stream_message_cannot_recreate_a_lost_node_claim() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("next-message.db");
    let (mut ledger, contract) = stream_properties::fixture(&path);
    ledger
        .enqueue_message(&stream_properties::message(&contract, 0, 0, 1))
        .expect("first reservation");
    corrupt(&path, true, 0);
    assert!(
        ledger
            .enqueue_message(&stream_properties::message(&contract, 1, 0, 1))
            .is_err()
    );
    assert_eq!(ledger.held("f").expect("hold"), 4);
    assert!(
        ledger
            .message_receipt("f", "emit", "m1")
            .expect("receipt")
            .is_none()
    );
}

#[test]
fn lost_message_projection_cannot_recycle_original_unknown_hold() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("lost-message.db");
    let (mut ledger, contract) = stream_properties::fixture(&path);
    let message = stream_properties::message(&contract, 0, 0, 1);
    ledger
        .enqueue_message(&message)
        .expect("original reservation");
    let owner = ledger
        .claim_stream(StreamClaim {
            family: "f",
            node: "emit",
            destination: &contract.destination,
            revision: 0,
            fence: 1,
        })
        .expect("original owner");
    let range = ledger
        .consume_range(&owner, "m0", 4)
        .expect("unknown consumed range");
    let connection = rusqlite::Connection::open(&path).expect("fault writer");
    connection
        .execute("DELETE FROM stream_ranges", [])
        .expect("lost range projection");
    connection
        .execute("DELETE FROM stream_messages", [])
        .expect("lost message projection");
    drop(connection);
    let mut calls = 0;
    assert!(
        ledger
            .write_range(&owner, range, |_| {
                calls += 1;
                WriteObservation::Complete
            })
            .is_err()
    );
    assert_eq!(calls, 0);
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert!(ledger.enqueue_message(&message).is_err());
    assert_eq!(ledger.held("f").expect("unknown hold"), 4);
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn mixed_request_and_stream_exposure_cannot_be_checked_in_separate_domains(held in 4u64..8) {
        let temp = tempfile::tempdir().expect("directory");
        let path = temp.path().join("mixed.db");
        let mut task = fixtures::task();
        task.budget = 12;
        task.node_cost_bounds.insert("n1".into(), 4);
        let contract = StreamContract {
            family: task.family.clone(), node: "n1".into(), profile: task.profile.clone(),
            target: "primary".into(), input_digest: task.body_digests["n1"].clone(),
            destination: "tcp://127.0.0.1:9000".into(),
            messages: vec![MessageRule { id: "m0".into(), max_bytes: 8, cost_bound: 4 }],
        };
        task.stream_contracts.insert("n1".into(), contract.digest().expect("contract"));
        let mut ledger = Ledger::open(&path).expect("ledger");
        ledger.publish(None, "permit(principal,action,resource);", 1).expect("policy");
        ledger.register_task(&task).expect("original task");
        ledger.register_stream(&contract).expect("stream");
        ledger.enqueue(&fixtures::proposal(0, 4)).expect("request");
        ledger.enqueue_message(&StreamMessage {
            family: task.family.clone(), node: "n1".into(), message: "m0".into(),
            contract_digest: contract.digest().expect("contract"), payload: "abcdefgh".into(),
            ceiling: 4, revision: 0, fence: 1,
        }).expect("message");
        let request = ledger.consume("family", "n0").expect("request consumption");
        let owner = ledger.claim_stream(StreamClaim { family: "family", node: "n1", destination: &contract.destination, revision: 0, fence: 1 }).expect("stream owner");
        let range = ledger.consume_range(&owner, "m0", 4).expect("range");
        let connection = rusqlite::Connection::open(&path).expect("fault writer");
        connection.execute("UPDATE tasks SET held=?1", [held as i64]).expect("inconsistent shared hold");
        drop(connection);
        let mut calls = 0;
        let dispatched = ledger.dispatch(request, |_| { calls += 1; });
        prop_assert!(dispatched.is_err());
        let written = ledger.write_range(&owner, range, |_| { calls += 1; WriteObservation::Complete });
        prop_assert!(written.is_err());
        prop_assert!(ledger.enqueue(&fixtures::proposal(2, 4)).is_err());
        prop_assert_eq!(calls, 0);
        prop_assert_eq!(ledger.held("family").expect("hold"), held);
        drop(ledger);
        let mut ledger = Ledger::open(&path).expect("restart");
        prop_assert!(ledger.enqueue(&fixtures::proposal(2, 4)).is_err());
        prop_assert_eq!(ledger.held("family").expect("hold"), held);
    }
    #[test]
    fn request_recovery_never_recreates_claim_or_accepts_unretained_exposure(
        fault in 0u8..6, phase in 0u8..3
    ) {
        let temp = tempfile::tempdir().expect("directory");
        let path = temp.path().join("requests.db");
        let mut ledger = fixtures::initialized(&path);
        ledger.enqueue(&fixtures::proposal(0, 4)).expect("first reservation");
        ledger.enqueue(&fixtures::proposal(1, 4)).expect("second reservation");
        let permit = if phase == 1 { Some(ledger.consume("family", "n0").expect("consume")) } else { None };
        corrupt(&path, false, fault);
        if phase == 2 { drop(ledger); ledger = Ledger::open(&path).expect("restart"); }
        let mut calls = 0;
        let outcome = if let Some(permit) = permit {
            ledger.dispatch(permit, |_| { calls += 1; })
        } else { ledger.consume("family", "n0").map(|_| ()) };
        prop_assert!(outcome.is_err(), "unretained request reached consumption or send");
        prop_assert_eq!(calls, 0);
        let connection = rusqlite::Connection::open(&path).expect("observe");
        let claims: i64 = connection.query_row("SELECT COUNT(*) FROM execution_claims", [], |row| row.get(0)).expect("claims");
        if fault == 0 { prop_assert_eq!(claims, 0, "open must not remint claims"); }
        prop_assert_eq!(ledger.held("family").expect("hold"), if fault == 3 { 4 } else if fault == 5 { 9 } else { 8 });
    }

    #[test]
    fn stream_recovery_requires_claim_and_exposure_at_custody_range_and_write(
        fault in 0u8..6, phase in 0u8..3
    ) {
        let temp = tempfile::tempdir().expect("directory");
        let path = temp.path().join("streams.db");
        let (mut ledger, contract) = stream_properties::fixture(&path);
        ledger.enqueue_message(&stream_properties::message(&contract, 0, 0, 1)).expect("first reservation");
        ledger.enqueue_message(&stream_properties::message(&contract, 1, 0, 1)).expect("second reservation");
        let owner = if phase > 0 { Some(ledger.claim_stream(StreamClaim {
            family: "f", node: "emit", destination: &contract.destination, revision: 0, fence: 1
        }).expect("owner")) } else { None };
        let range = if phase == 2 { Some(ledger.consume_range(owner.as_ref().expect("owner"), "m0", 4).expect("range")) } else { None };
        corrupt(&path, true, fault);
        let mut calls = 0;
        let result = if let Some(range) = range {
            ledger.write_range(owner.as_ref().expect("owner"), range, |_| { calls += 1; WriteObservation::Complete }).map(|_| ())
        } else if let Some(owner) = owner {
            ledger.consume_range(&owner, "m0", 4).map(|_| ())
        } else { ledger.claim_stream(StreamClaim {
            family: "f", node: "emit", destination: &contract.destination, revision: 0, fence: 1
        }).map(|_| ()) };
        prop_assert!(result.is_err(), "unretained stream reached custody or send");
        prop_assert_eq!(calls, 0);
        prop_assert_eq!(ledger.held("f").expect("hold"), if fault == 3 { 4 } else { 8 });
    }
}

#[test]
fn balanced_projection_cannot_shrink_another_original_reservation() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("balanced.db");
    let mut ledger = Ledger::open(&path).expect("ledger");
    ledger.publish(None, fixtures::POLICY, 1).expect("policy");
    let mut task = fixtures::task();
    task.budget = 7;
    ledger.register_task(&task).expect("original budget");
    ledger
        .enqueue(&fixtures::proposal(0, 4))
        .expect("original hold");
    let permit = ledger.consume("family", "n0").expect("unknown original");
    drop(permit);
    drop(ledger);
    let connection = rusqlite::Connection::open(&path).expect("fault writer");
    connection.execute_batch("BEGIN IMMEDIATE; UPDATE operations SET reserved=1 WHERE node='n0'; UPDATE tasks SET held=1; COMMIT;").expect("balanced incomplete recovery");
    drop(connection);
    let mut recovered = Ledger::open(&path).expect("restart");
    assert!(recovered.enqueue(&fixtures::proposal(1, 4)).is_err());
    assert!(recovered.lookup("family", "n1").expect("observe").is_none());
    assert_eq!(recovered.held("family").expect("unchanged projection"), 1);
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn balanced_shrink_never_admits_a_different_node(original in 4u64..13, projected in 1u64..4, restart in proptest::bool::ANY) {
        let temp=tempfile::tempdir().expect("directory");
        let path=temp.path().join("balanced-property.db");
        let mut ledger=Ledger::open(&path).expect("ledger");
        ledger.publish(None,fixtures::POLICY,1).expect("policy");
        let mut task=fixtures::task();
        task.budget=original+3;
        ledger.register_task(&task).expect("original budget");
        ledger.enqueue(&fixtures::proposal(0,original)).expect("original hold");
        let permit=ledger.consume("family","n0").expect("consumption");
        drop(permit);
        let connection=rusqlite::Connection::open(&path).expect("fault writer");
        connection.execute("UPDATE operations SET reserved=?1 WHERE node='n0'",[projected as i64]).expect("row projection");
        connection.execute("UPDATE tasks SET held=?1",[projected as i64]).expect("balanced aggregate");
        drop(connection);
        if restart { drop(ledger);ledger=Ledger::open(&path).expect("restart"); }
        prop_assert!(ledger.enqueue(&fixtures::proposal(1,4)).is_err());
        prop_assert!(ledger.lookup("family","n1").expect("observation").is_none());
        prop_assert_eq!(ledger.held("family").expect("projection"),projected);
    }
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn balanced_stream_projection_never_funds_the_next_logical_message(
        original in 5u64..9, restart in proptest::bool::ANY
    ) {
        let temp=tempfile::tempdir().expect("directory");
        let path=temp.path().join("balanced-stream.db");
        let (mut ledger,contract)=stream_properties::fixture(&path);
        let mut first=stream_properties::message(&contract,0,0,1);first.ceiling=original;
        ledger.enqueue_message(&first).expect("original message hold");
        let owner=ledger.claim_stream(StreamClaim{family:"f",node:"emit",destination:&contract.destination,revision:0,fence:1}).expect("custody");
        let permit=ledger.consume_range(&owner,"m0",4).expect("unknown original range");
        drop(permit);drop(owner);
        let connection=rusqlite::Connection::open(&path).expect("fault writer");
        connection.execute_batch("BEGIN IMMEDIATE; UPDATE stream_messages SET reserved=1 WHERE message='m0'; UPDATE tasks SET held=1; COMMIT;").expect("balanced incomplete recovery");
        drop(connection);
        if restart {drop(ledger);ledger=Ledger::open(&path).expect("restart");}
        prop_assert!(ledger.enqueue_message(&stream_properties::message(&contract,1,0,1)).is_err());
        prop_assert!(ledger.message_receipt("f","emit","m1").expect("observation").is_none());
        prop_assert_eq!(ledger.held("f").expect("unchanged projection"),1);
    }
}

#[test]
fn lost_reservation_row_cannot_fund_a_different_request() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("orphaned-family.db");
    let mut ledger = Ledger::open(&path).expect("ledger");
    ledger.publish(None, fixtures::POLICY, 1).expect("policy");
    let mut task = fixtures::task();
    task.budget = 7;
    ledger.register_task(&task).expect("original task");
    ledger
        .enqueue(&fixtures::proposal(0, 4))
        .expect("original hold");
    drop(ledger.consume("family", "n0").expect("unknown original"));
    drop(ledger);
    let connection = rusqlite::Connection::open(&path).expect("fault writer");
    connection
        .execute_batch("BEGIN IMMEDIATE; DELETE FROM operations; UPDATE tasks SET held=0; COMMIT;")
        .expect("missing row and aggregate");
    drop(connection);
    let mut recovered = Ledger::open(&path).expect("restart");
    assert!(recovered.enqueue(&fixtures::proposal(1, 4)).is_err());
    assert!(
        recovered
            .lookup("family", "n1")
            .expect("observation")
            .is_none()
    );
    assert_eq!(recovered.held("family").expect("unrepaired projection"), 0);
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn lost_stream_reservation_row_keeps_orphaned_claim_budget_blocked(original in 5u64..9, restart in proptest::bool::ANY) {
        let temp=tempfile::tempdir().expect("directory");let path=temp.path().join("orphaned-stream.db");
        let (mut ledger,contract)=stream_properties::fixture(&path);
        let mut first=stream_properties::message(&contract,0,0,1);first.ceiling=original;
        ledger.enqueue_message(&first).expect("original hold");
        let owner=ledger.claim_stream(StreamClaim{family:"f",node:"emit",destination:&contract.destination,revision:0,fence:1}).expect("custody");
        drop(ledger.consume_range(&owner,"m0",4).expect("unknown original range"));drop(owner);
        let connection=rusqlite::Connection::open(&path).expect("fault writer");
        connection.execute_batch("BEGIN IMMEDIATE; DELETE FROM stream_ranges; DELETE FROM stream_messages; UPDATE tasks SET held=0; COMMIT;").expect("lost reservation and aggregate");drop(connection);
        if restart {drop(ledger);ledger=Ledger::open(&path).expect("restart");}
        prop_assert!(ledger.enqueue_message(&stream_properties::message(&contract,1,0,1)).is_err());
        prop_assert!(ledger.message_receipt("f","emit","m1").expect("observe").is_none());
        prop_assert_eq!(ledger.held("f").expect("unrepaired projection"),0);
    }
}

#[test]
fn surviving_stream_message_cannot_hide_a_lost_unknown_reservation() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("partial-message-loss.db");
    let (mut ledger, contract) = stream_properties::fixture(&path);
    let original = stream_properties::message(&contract, 0, 0, 1);
    ledger.enqueue_message(&original).expect("first hold");
    ledger
        .enqueue_message(&stream_properties::message(&contract, 1, 0, 1))
        .expect("surviving hold");
    let owner = ledger
        .claim_stream(StreamClaim {
            family: "f",
            node: "emit",
            destination: &contract.destination,
            revision: 0,
            fence: 1,
        })
        .expect("custody");
    drop(
        ledger
            .consume_range(&owner, "m0", 4)
            .expect("unknown consumed range"),
    );
    drop(owner);
    let connection = rusqlite::Connection::open(&path).expect("fault writer");
    connection.execute_batch("BEGIN IMMEDIATE; DELETE FROM stream_ranges WHERE message='m0'; DELETE FROM stream_messages WHERE message='m0'; UPDATE tasks SET held=4; COMMIT;").expect("partial loss with balanced aggregate");
    drop(connection);
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert!(
        ledger.enqueue_message(&original).is_err(),
        "a surviving node claim must not recreate the lost original message"
    );
    assert_eq!(ledger.held("f").expect("unrepaired projection"), 4);
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn exact_message_manifest_guards_recovery_and_existing_write_handles(fault in 0u8..4, restart in proptest::bool::ANY) {
        let temp=tempfile::tempdir().expect("directory");let path=temp.path().join("manifest.db");
        let (mut ledger,contract)=stream_properties::fixture(&path);
        ledger.enqueue_message(&stream_properties::message(&contract,0,0,1)).expect("first hold");
        ledger.enqueue_message(&stream_properties::message(&contract,1,0,1)).expect("second hold");
        let owner=ledger.claim_stream(StreamClaim{family:"f",node:"emit",destination:&contract.destination,revision:0,fence:1}).expect("custody");
        let permit=ledger.consume_range(&owner,"m0",4).expect("original pending write");
        let connection=rusqlite::Connection::open(&path).expect("fault writer");
        let original:String=connection.query_row("SELECT reservations FROM execution_claims",[],|row|row.get(0)).expect("retained manifest");
        let sql=match fault {
            0=>"DELETE FROM stream_messages WHERE message='m1'; UPDATE tasks SET held=4;",
            1=>"UPDATE stream_messages SET message='shadow',proposal=json_set(proposal,'$.message','shadow') WHERE message='m1';",
            2=>"UPDATE stream_messages SET digest='substituted' WHERE message='m1';",
            _=>"UPDATE stream_messages SET reserved=3,proposal=json_set(proposal,'$.ceiling',3) WHERE message='m1'; UPDATE tasks SET held=7;",
        };
        connection.execute_batch(sql).expect("inconsistent recovered projection");
        let expected=ledger.held("f").expect("damaged aggregate");
        let mut calls=0;
        let result=ledger.write_range(&owner,permit,|_|{calls+=1;WriteObservation::Complete});
        prop_assert!(result.is_err());
        prop_assert_eq!(calls,0);
        drop(owner);
        if restart {drop(ledger);ledger=Ledger::open(&path).expect("restart");}
        let custody=ledger.claim_stream(StreamClaim{family:"f",node:"emit",destination:&contract.destination,revision:0,fence:1});
        prop_assert!(custody.is_err());
        let after:String=connection.query_row("SELECT reservations FROM execution_claims",[],|row|row.get(0)).expect("unchanged manifest");
        prop_assert_eq!(after,original);
        prop_assert_eq!(ledger.held("f").expect("unrepaired projection"),expected);
    }
}

#[test]
fn old_claim_schema_is_not_backfilled_from_surviving_rows() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("unqualified-claim-schema.db");
    let connection = rusqlite::Connection::open(&path).expect("old image");
    connection.execute_batch("CREATE TABLE execution_claims(family TEXT,node TEXT,kind TEXT,PRIMARY KEY(family,node)); INSERT INTO execution_claims VALUES('f','emit','stream');").expect("old retained claim");
    assert!(Ledger::open(&path).is_err());
    let columns: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('execution_claims') WHERE name='reservations'",
            [],
            |row| row.get(0),
        )
        .expect("schema observation");
    assert_eq!(columns, 0);
}

#[test]
fn concurrent_message_admission_preserves_both_manifest_members() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("concurrent-members.db");
    let (ledger, contract) = stream_properties::fixture(&path);
    drop(ledger);
    std::thread::scope(|scope| {
        let workers: Vec<_> = (0..2)
            .map(|id| {
                let path = &path;
                let contract = &contract;
                scope.spawn(move || {
                    let mut ledger = Ledger::open(path).expect("owner");
                    ledger
                        .enqueue_message(&stream_properties::message(contract, id, 0, 1))
                        .expect("atomic admission");
                })
            })
            .collect();
        for worker in workers {
            worker.join().expect("admission worker");
        }
    });
    let mut ledger = Ledger::open(&path).expect("recovery");
    assert_eq!(ledger.held("f").expect("both holds"), 8);
    let connection = rusqlite::Connection::open(&path).expect("manifest observation");
    let members: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM execution_claims,json_each(reservations)",
            [],
            |row| row.get(0),
        )
        .expect("member count");
    assert_eq!(members, 2);
    let owner = ledger
        .claim_stream(StreamClaim {
            family: "f",
            node: "emit",
            destination: &contract.destination,
            revision: 0,
            fence: 1,
        })
        .expect("matching manifest custody");
    let permit = ledger.consume_range(&owner, "m0", 4).expect("bound range");
    let mut calls = 0;
    ledger
        .write_range(&owner, permit, |_| {
            calls += 1;
            WriteObservation::Complete
        })
        .expect("final-use join");
    assert_eq!(calls, 1);
}

#[test]
fn exhausted_budget_cannot_publish_a_manifest_member_without_its_row() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("failed-member.db");
    let (mut ledger, contract) = stream_properties::fixture(&path);
    let mut first = stream_properties::message(&contract, 0, 0, 1);
    first.ceiling = 5;
    ledger.enqueue_message(&first).expect("first hold");
    assert!(
        ledger
            .enqueue_message(&stream_properties::message(&contract, 1, 0, 1))
            .is_err()
    );
    let connection = rusqlite::Connection::open(&path).expect("observation");
    let members: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM execution_claims,json_each(reservations) WHERE key='m1'",
            [],
            |row| row.get(0),
        )
        .expect("rollback evidence");
    assert_eq!(members, 0);
    assert_eq!(ledger.held("f").expect("original hold"), 5);
    assert!(
        ledger
            .message_receipt("f", "emit", "m1")
            .expect("historical observation")
            .is_none()
    );
}

#[test]
fn selected_message_binding_must_match_its_committed_digest_at_final_write() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("selected-binding.db");
    let (mut ledger, contract) = stream_properties::fixture(&path);
    ledger
        .enqueue_message(&stream_properties::message(&contract, 0, 0, 1))
        .expect("reservation");
    let owner = ledger
        .claim_stream(StreamClaim {
            family: "f",
            node: "emit",
            destination: &contract.destination,
            revision: 0,
            fence: 1,
        })
        .expect("custody");
    let permit = ledger
        .consume_range(&owner, "m0", 4)
        .expect("pending range");
    let connection = rusqlite::Connection::open(&path).expect("fault writer");
    connection
        .execute(
            "UPDATE stream_messages SET proposal=json_set(proposal,'$.payload_digest',?1)",
            [weaver_contracts::body_digest("substituted")],
        )
        .expect("substituted selected facts");
    let mut calls = 0;
    assert!(
        ledger
            .write_range(&owner, permit, |_| {
                calls += 1;
                WriteObservation::Complete
            })
            .is_err()
    );
    assert_eq!(calls, 0);
    assert_eq!(ledger.held("f").expect("original unknown exposure"), 4);
}
