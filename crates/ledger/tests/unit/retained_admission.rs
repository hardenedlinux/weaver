//! Retained admission/exposure profile tests over the existing Floor owner.
use super::{Floor, SCOPE, cut};
use std::{collections::BTreeSet, path::Path};
use weaver_contracts::{ProviderReceipt, ProviderState};
use weaver_ledger::Ledger;

impl Floor {
    // Test-only refinement of this existing owner: the full typed exposure
    // receipt and one-use burn enter its prefix in the same Turso transaction.
    fn send_with_retained_exposure(
        &mut self,
        projection: &Path,
        observed_epoch: i64,
        key: &str,
        receipt: &ProviderReceipt,
        after_burn: impl FnOnce(&weaver_ledger::persistence::driver::Connection),
        send: impl FnOnce(),
    ) -> bool {
        let observed_cut =
            cut(&weaver_ledger::persistence::Session::open(projection)
                .expect("observed projection"));
        self.send_bound_record(
            (projection, observed_epoch, &observed_cut, key),
            Some(receipt),
            after_burn,
            send,
        )
    }
    fn qualified_exposure(
        &self,
        projection: &Path,
        observed_epoch: i64,
        key: &str,
        ledger: &Ledger,
    ) -> bool {
        if !self.qualified(projection, observed_epoch) {
            return false;
        }
        let body: Option<String> = weaver_ledger::persistence::maybe(
            &self.0,
            "SELECT body FROM prefix WHERE kind=4 AND k=?1",
            weaver_ledger::persistence::params![(key).to_owned()],
            |row| row.get(0),
        )
        .expect("retained admission body");
        let Some(body) = body else {
            return false;
        };
        let (scope, bound_key, expected): (String, String, ProviderReceipt) =
            serde_json::from_str(&body).expect("typed original exposure");
        let burned: bool = weaver_ledger::persistence::one(
            &self.0,
            "SELECT EXISTS(SELECT 1 FROM burned WHERE k=?1)",
            weaver_ledger::persistence::params![(key).to_owned()],
            |row| row.get(0),
        )
        .expect("retained burn projection");
        let actual = ledger
            .provider_receipt(&expected.family, &expected.node)
            .expect("actual exposure projection");
        scope == SCOPE
            && bound_key == key
            && burned
            && expected.state == ProviderState::Unknown
            && ledger
                .held(&expected.family)
                .expect("actual held projection")
                == expected.held
            && actual.as_ref().map(|receipt| {
                serde_json::to_string(&(SCOPE, key, receipt)).expect("actual canonical receipt")
            }) == Some(body)
    }
}

#[test]
fn retained_admission_reply_loss_and_gateway_restore_do_not_release_exposure() {
    let temp = tempfile::tempdir().expect("directory");
    let gateway = temp.path().join("gateway.db");
    let snapshot = temp.path().join("before-reservation.db");
    let projection = temp.path().join("projection.db");
    let floor_path = temp.path().join("authority.db");
    let (ledger, plan) = super::super::fixture(&gateway);
    ledger.close().expect("closed snapshot source");
    crate::snapshot::copy_closed(&gateway, &snapshot).expect("pre-reservation snapshot");
    let mut ledger = Ledger::open(&gateway).expect("original owner");
    ledger
        .enqueue_provider(&plan)
        .expect("original reservation");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("original consumption");
    let receipt = ledger
        .provider_receipt("f", "infer")
        .expect("receipt")
        .expect("original run");
    let mut floor = Floor::open(&floor_path);
    let command = floor.command("original-consumption", 1, "f/infer");
    floor.stage(&command);
    assert!(floor.commit(&command).0);
    floor.repair(&projection);
    let mut calls = 0;
    assert!(floor.send_with_retained_exposure(
        &projection,
        0,
        "f/infer",
        &receipt,
        |_| {},
        || {
            ledger
                .dispatch_provider(&permit, || calls += 1)
                .expect("actual dispatch");
        }
    ));
    drop(floor); // Lose the completed response, not its deciding record.
    floor = Floor::open(&floor_path);
    floor.repair(&projection);
    assert!(floor.qualified_exposure(&projection, 0, "f/infer", &ledger));
    assert!(!floor.send_with_retained_exposure(
        &projection,
        0,
        "f/infer",
        &receipt,
        |_| {},
        || calls += 1
    ));
    ledger.close().expect("closed restore target");
    crate::snapshot::copy_closed(&snapshot, &gateway).expect("restore gateway only");
    let recovered = Ledger::open(&gateway).expect("old worker image");
    assert_eq!(recovered.held("f").expect("stale projection"), 0);
    assert!(
        !floor.qualified_exposure(&projection, 0, "f/infer", &recovered),
        "zero local hold is not a release receipt"
    );
    let body: String = weaver_ledger::persistence::one(
        &floor.0,
        "SELECT body FROM prefix WHERE kind=4 AND k='f/infer'",
        (),
        |row| row.get(0),
    )
    .expect("retained original body");
    let (_, _, retained): (String, String, ProviderReceipt) =
        serde_json::from_str(&body).expect("typed retained exposure");
    assert_eq!(
        (retained.reserved, retained.held, retained.state),
        (4, 4, ProviderState::Unknown)
    );
    floor.rotate();
    assert!(!floor.qualified_exposure(&projection, 0, "f/infer", &recovered));
    assert!(!floor.send_with_retained_exposure(
        &projection,
        1,
        "f/infer",
        &receipt,
        |_| {},
        || calls += 1
    ));
    assert_eq!(calls, 1);
}

#[test]
fn retained_admission_prefix_failure_atomically_rolls_back_burn() {
    let temp = tempfile::tempdir().expect("directory");
    let gateway = temp.path().join("gateway.db");
    let projection = temp.path().join("projection.db");
    let floor_path = temp.path().join("authority.db");
    let (mut ledger, plan) = super::super::fixture(&gateway);
    ledger.enqueue_provider(&plan).expect("reservation");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consumption");
    let receipt = ledger
        .provider_receipt("f", "infer")
        .expect("receipt")
        .expect("original run");
    let mut floor = Floor::open(&floor_path);
    let command = floor.command("original-consumption", 1, "f/infer");
    floor.stage(&command);
    assert!(floor.commit(&command).0);
    floor.repair(&projection);
    weaver_ledger::persistence::script(&floor.0, "CREATE TRIGGER fail_admission BEFORE INSERT ON prefix WHEN NEW.kind=4 BEGIN SELECT RAISE(ABORT,'injected admission prefix failure'); END;").expect("fault injection");
    let mut calls = 0;
    assert!(!floor.send_with_retained_exposure(
        &projection,
        0,
        "f/infer",
        &receipt,
        |_| {},
        || calls += 1
    ));
    drop(floor);
    floor = Floor::open(&floor_path);
    let burns: i64 =
        weaver_ledger::persistence::one(&floor.0, "SELECT COUNT(*) FROM burned", (), |row| {
            row.get(0)
        })
        .expect("burn count");
    let admissions: i64 = weaver_ledger::persistence::one(
        &floor.0,
        "SELECT COUNT(*) FROM prefix WHERE kind=4",
        (),
        |row| row.get(0),
    )
    .expect("admission count");
    assert_eq!((burns, admissions, calls), (0, 0, 0));
    assert_eq!(ledger.held("f").expect("unknown reservation retained"), 4);
    weaver_ledger::persistence::script(&floor.0, "DROP TRIGGER fail_admission")
        .expect("remove fault");
    assert!(floor.send_with_retained_exposure(
        &projection,
        0,
        "f/infer",
        &receipt,
        |_| {},
        || {
            ledger
                .dispatch_provider(&permit, || calls += 1)
                .expect("same original continuation");
        }
    ));
    floor.repair(&projection);
    assert!(floor.qualified_exposure(&projection, 0, "f/infer", &ledger));
    assert_eq!(calls, 1);
}

#[test]
fn retained_prefix_without_burn_projection_cannot_repeat_admission() {
    let temp = tempfile::tempdir().expect("directory");
    let gateway = temp.path().join("gateway.db");
    let projection = temp.path().join("projection.db");
    let (mut ledger, plan) = super::super::fixture(&gateway);
    ledger.enqueue_provider(&plan).expect("reservation");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consumption");
    let receipt = ledger
        .provider_receipt("f", "infer")
        .expect("receipt")
        .expect("original run");
    let mut floor = Floor::open(&temp.path().join("authority.db"));
    let command = floor.command("original-consumption", 1, "f/infer");
    floor.stage(&command);
    assert!(floor.commit(&command).0);
    floor.repair(&projection);
    let mut calls = 0;
    assert!(floor.send_with_retained_exposure(
        &projection,
        0,
        "f/infer",
        &receipt,
        |_| {},
        || {
            ledger
                .dispatch_provider(&permit, || calls += 1)
                .expect("actual dispatch");
        }
    ));
    floor.repair(&projection);
    weaver_ledger::persistence::exec(&floor.0, "DELETE FROM burned", ())
        .expect("partial projection loss");
    assert!(
        floor.qualified(&projection, 0),
        "prefix equality alone remains insufficient"
    );
    assert!(!floor.qualified_exposure(&projection, 0, "f/infer", &ledger));
    assert!(!floor.send_with_retained_exposure(
        &projection,
        0,
        "f/infer",
        &receipt,
        |_| {},
        || calls += 1
    ));
    assert_eq!(
        calls, 1,
        "retained prefix admission prevents recreating the lost burn"
    );
    assert_eq!(ledger.held("f").expect("unknown exposure remains held"), 4);
}

#[test]
fn retained_burn_fenced_before_callback_keeps_original_unknown_exposure() {
    let temp = tempfile::tempdir().expect("directory");
    let gateway = temp.path().join("gateway.db");
    let projection = temp.path().join("projection.db");
    let floor_path = temp.path().join("authority.db");
    let (mut ledger, plan) = super::super::fixture(&gateway);
    ledger.enqueue_provider(&plan).expect("reservation");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consumption");
    let receipt = ledger
        .provider_receipt("f", "infer")
        .expect("receipt")
        .expect("original run");
    let mut floor = Floor::open(&floor_path);
    let command = floor.command("original-consumption", 1, "f/infer");
    floor.stage(&command);
    assert!(floor.commit(&command).0);
    floor.repair(&projection);
    let mut calls = 0;
    assert!(!floor.send_with_retained_exposure(
        &projection,
        0,
        "f/infer",
        &receipt,
        |db| {
            weaver_ledger::persistence::exec(db, "UPDATE owner SET epoch=epoch+1", ())
                .expect("fence after committed burn");
        },
        || {
            ledger
                .dispatch_provider(&permit, || calls += 1)
                .expect("actual callback");
        }
    ));
    drop(floor);
    floor = Floor::open(&floor_path);
    floor.repair(&projection);
    assert!(
        floor.qualified_exposure(&projection, 1, "f/infer", &ledger),
        "recovered data is not a reconstructed send ticket"
    );
    assert!(!floor.send_with_retained_exposure(
        &projection,
        1,
        "f/infer",
        &receipt,
        |_| {},
        || calls += 1
    ));
    assert_eq!(calls, 0);
    assert_eq!(
        ledger
            .held("f")
            .expect("unknown exposure despite omitted callback"),
        4
    );
    assert_eq!(
        ledger
            .provider_receipt("f", "infer")
            .expect("receipt")
            .expect("original run")
            .state,
        ProviderState::Unknown
    );
}
