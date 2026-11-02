use super::fixtures;
use proptest::{collection, prop_assert, prop_assert_eq, proptest, test_runner::Config};
use std::collections::{BTreeMap, BTreeSet};
use weaver_contracts::{Publication, PublicationOutcome};
use weaver_ledger::Ledger;

fn source(id: &str, parent: u64) -> Publication {
    Publication {
        operation_id: id.into(),
        expected_revision: Some(parent),
        fence: 2,
        policy: "permit(principal,action,resource);".into(),
        schema: include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../prod/policies/provider/schema.json"
        ))
        .into(),
    }
}

#[test]
fn lost_birth_projection_cannot_authorize_or_be_silently_repaired() {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("lost-birth.db");
    let mut ledger = Ledger::open(&path).expect("ledger");
    let original = source("birth-commit", 0);
    ledger
        .publish_typed(None, &original.policy, &original.schema, 1)
        .expect("authority");
    let key = ledger.stage_authority(&original).expect("stage");
    let task = fixtures::task();
    ledger
        .register_published_task(&task, &key)
        .expect("original task");
    assert_eq!(
        ledger
            .publish_authority(&original)
            .expect("birth commit")
            .outcome,
        PublicationOutcome::Committed
    );
    let mut proposal = fixtures::proposal(0, 1);
    proposal.revision = 1;
    proposal.fence = 2;
    ledger.enqueue(&proposal).expect("hold");
    let permit = ledger.consume("family", "n0").expect("consumed");
    let fault = weaver_ledger::persistence::Session::open(&path).expect("fault writer");
    weaver_ledger::persistence::exec(
        &fault,
        "DELETE FROM task_publications WHERE family='family'",
        (),
    )
    .expect("partial recovery");
    assert!(
        ledger
            .dispatch(permit, |_| panic!("lost birth reached transport"))
            .is_err()
    );
    assert!(ledger.register_task(&task).is_err());
    assert!(ledger.register_published_task(&task, &key).is_err());
    assert_eq!(ledger.held("family").expect("unknown hold"), 1);
}

#[test]
fn rejected_task_birth_cannot_execute_under_an_unrelated_allowing_policy() {
    let temp = tempfile::tempdir().expect("store");
    let path = temp.path().join("birth.db");
    let mut ledger = Ledger::open(&path).expect("ledger");
    let original = source("rejected-birth", 99);
    ledger
        .publish_typed(None, &original.policy, &original.schema, 1)
        .expect("old allowing image");
    let key = ledger.stage_authority(&original).expect("stage");
    let task = fixtures::task();
    let proposal = fixtures::proposal(0, 1);
    ledger
        .register_published_task(&task, &key)
        .expect("inert task registration");
    assert!(ledger.enqueue(&proposal).is_err());
    assert_eq!(
        ledger
            .publish_authority(&original)
            .expect("conflict")
            .outcome,
        PublicationOutcome::Rejected
    );
    // No global pending row remains; the unrelated old Policy still permits.
    assert!(
        ledger.enqueue(&proposal).is_err(),
        "rejected task activated under old Policy"
    );
    ledger
        .register_task(&task)
        .expect("exact direct registration replay");
    assert!(
        ledger.enqueue(&proposal).is_err(),
        "omitting the birth erased its authority binding"
    );
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert!(ledger.enqueue(&proposal).is_err());
    assert_eq!(ledger.held(&task.family).expect("hold"), 0);
}

#[test]
fn committed_task_birth_is_preserved_across_later_policy_publications() {
    let temp = tempfile::tempdir().expect("store");
    let path = temp.path().join("birth.db");
    let mut ledger = Ledger::open(&path).expect("ledger");
    let first = source("birth", 0);
    ledger
        .publish_typed(None, &first.policy, &first.schema, 1)
        .expect("old image");
    let key = ledger.stage_authority(&first).expect("stage");
    let task = fixtures::task();
    ledger
        .register_published_task(&task, &key)
        .expect("register");
    ledger
        .publish_authority(&first)
        .expect("activate original birth");
    let mut proposal = fixtures::proposal(0, 1);
    proposal.revision = 1;
    proposal.fence = 2;
    ledger
        .enqueue(&proposal)
        .expect("published task positive control");
    let mut later = source("later", 1);
    later.fence = 3;
    let later_key = ledger.stage_authority(&later).expect("later stage");
    ledger
        .register_published_task(&task, &later_key)
        .expect("same original task");
    ledger.publish_authority(&later).expect("later Policy");
    let mut second = fixtures::proposal(1, 1);
    second.revision = 2;
    second.fence = 3;
    ledger
        .enqueue(&second)
        .expect("original birth remains committed");
    assert_eq!(ledger.held(&task.family).expect("original hold"), 2);
}

#[derive(Clone, Copy, Debug)]
enum Command {
    Stage(u8),
    Register(u8),
    Decide(u8),
    Probe(u8),
    UnboundReplay,
    Restart,
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn original_task_birth_refines_independent_admission_model(suffix in collection::vec((0u8..6,0u8..8),1..32)) {
        let temp=tempfile::tempdir().expect("store");let path=temp.path().join("model.db");
        let mut ledger=Ledger::open(&path).expect("ledger");let schema=source("unused",0);
        ledger.publish_typed(None,&schema.policy,&schema.schema,1).expect("allowing original image");
        let task=fixtures::task();let mut birth:Option<u8>=None;
        let mut pending=BTreeSet::new();let mut decisions=BTreeMap::new();
        let mut claims=BTreeMap::<u8,weaver_contracts::Proposal>::new();let mut revision=0;let mut fence=1;
        let commands=[Command::Stage(0),Command::Register(0)].into_iter().chain(suffix.into_iter().map(|(kind,id)|match kind {
            0=>Command::Stage(id%2),1=>Command::Register(id%2),2=>Command::Decide(id%2),
            3=>Command::Probe(id),4=>Command::UnboundReplay,_=>Command::Restart,
        }));
        for command in commands {
            match command {
                Command::Stage(id)=>{
                    if !decisions.contains_key(&id){pending.insert(id);}
                    ledger.stage_authority(&source(&format!("source-{id}"),0)).expect("stage");
                },
                Command::Register(id)=>{
                    let expected=birth.is_none_or(|old|old==id || decisions.get(&old)==Some(&PublicationOutcome::Committed));
                    let p=source(&format!("source-{id}"),0);
                    let key=weaver_contracts::PublicationKey{operation_id:p.operation_id.clone(),digest:p.digest().expect("key")};
                    prop_assert_eq!(ledger.register_published_task(&task,&key).is_ok(),expected);
                    if expected && birth.is_none(){birth=Some(id);}
                },
                Command::Decide(id)=>{
                    let expected=*decisions.entry(id).or_insert_with(||if revision==0{
                        revision=1;fence=2;PublicationOutcome::Committed
                    }else{PublicationOutcome::Rejected});
                    pending.remove(&id);
                    prop_assert_eq!(ledger.publish_authority(&source(&format!("source-{id}"),0)).expect("decision").outcome,expected);
                },
                Command::Probe(id)=>{
                    let mut proposal=fixtures::proposal(id,1);proposal.revision=revision;proposal.fence=fence;
                    let expected=claims.contains_key(&id) || (pending.is_empty() && birth.is_some_and(|key|decisions.get(&key)==Some(&PublicationOutcome::Committed)));
                    if let Some(original)=claims.get(&id){proposal=original.clone();}
                    else if expected {claims.insert(id,proposal.clone());}
                    prop_assert_eq!(ledger.enqueue(&proposal).is_ok(),expected);
                },
                Command::UnboundReplay=>ledger.register_task(&task).expect("unchanged original task"),
                Command::Restart=>{drop(ledger);ledger=Ledger::open(&path).expect("restart");},
            }
            if birth.is_some() {prop_assert_eq!(ledger.held(&task.family).expect("held"),claims.len() as u64);}
            else {prop_assert!(ledger.held(&task.family).is_err(),"missing task was treated as an empty account");}
        }
    }
}
