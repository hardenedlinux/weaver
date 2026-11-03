// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Executable protocol reference, not a deployed independent authority.
//! Two files only define this test's restore boundary; they do not establish
//! failure-domain independence. Domain payload validation stays with its owner.
use std::{collections::BTreeSet, path::Path};
use weaver_contracts::{ProviderReceipt, ProviderState};
use weaver_ledger::Ledger;
use weaver_ledger::persistence::Session;
#[path = "retained_admission.rs"]
mod retained_admission;
#[path = "transport_owner.rs"]
mod transport_owner;

const SCOPE: &str = "original-task/profile/claim/budget/history";
#[derive(Clone)]
struct Command {
    id: String,
    kind: i64,
    key: String,
    body: String,
    before: String,
    epoch: i64,
}
impl Command {
    fn canonical(&self) -> String {
        serde_json::json!([
            SCOPE,
            self.id,
            self.kind,
            self.key,
            self.body,
            self.before,
            self.epoch
        ])
        .to_string()
    }
}
struct Floor(Session);
fn cut(db: &weaver_ledger::persistence::driver::Connection) -> String {
    let entries = weaver_ledger::persistence::read_all(
        db,
        "SELECT kind,k,body FROM prefix ORDER BY ordinal",
        (),
        |r| Ok((r.get::<i64>(0)?, r.get::<String>(1)?, r.get::<String>(2)?)),
    )
    .expect("complete prefix");
    serde_json::to_string(&entries).expect("canonical full prefix")
}
fn epoch(db: &weaver_ledger::persistence::driver::Connection) -> i64 {
    weaver_ledger::persistence::one(db, "SELECT epoch FROM owner", (), |r| r.get(0)).expect("epoch")
}
fn unknown(db: &weaver_ledger::persistence::driver::Connection) -> bool {
    weaver_ledger::persistence::one(db, "SELECT EXISTS(SELECT 1 FROM pending p LEFT JOIN outcomes o ON p.id=o.id WHERE o.id IS NULL)", (), |r|r.get(0)).expect("pending outcomes")
}
impl Floor {
    fn open(path: &Path) -> Self {
        let db = Session::open(path).expect("authority store");
        weaver_ledger::persistence::script(&db, "
            CREATE TABLE IF NOT EXISTS owner(epoch INTEGER NOT NULL);
            INSERT INTO owner SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM owner);
            CREATE TABLE IF NOT EXISTS prefix(ordinal INTEGER PRIMARY KEY,kind INTEGER,k TEXT,body TEXT);
            CREATE TABLE IF NOT EXISTS pending(id TEXT PRIMARY KEY,command TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS outcomes(id TEXT PRIMARY KEY,command TEXT NOT NULL,accepted INTEGER NOT NULL,post TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS burned(k TEXT PRIMARY KEY);").expect("authority schema");
        Self(db)
    }
    fn command(&self, id: &str, kind: i64, key: &str) -> Command {
        Command {
            id: id.into(),
            kind,
            key: key.into(),
            body: format!("canonical-{id}"),
            before: cut(&self.0),
            epoch: epoch(&self.0),
        }
    }
    fn stage(&self, c: &Command) {
        weaver_ledger::persistence::exec(
            &self.0,
            "INSERT OR IGNORE INTO pending VALUES(?1,?2)",
            weaver_ledger::persistence::params![(c.id).to_owned(), (c.canonical()).to_owned()],
        )
        .expect("durable prepare");
        let frozen: String = weaver_ledger::persistence::one(
            &self.0,
            "SELECT command FROM pending WHERE id=?1",
            weaver_ledger::persistence::params![c.id.to_owned()],
            |r| r.get(0),
        )
        .expect("prepared");
        assert_eq!(
            frozen,
            c.canonical(),
            "ID cannot change its original command"
        );
    }
    fn inspect(&self, c: &Command) -> Option<(bool, String)> {
        Self::inspect_at(&self.0, c)
    }
    fn inspect_at(
        db: &weaver_ledger::persistence::driver::Connection,
        c: &Command,
    ) -> Option<(bool, String)> {
        weaver_ledger::persistence::maybe(
            db,
            "SELECT command,accepted,post FROM outcomes WHERE id=?1",
            weaver_ledger::persistence::params![c.id.to_owned()],
            |r| Ok((r.get::<String>(0)?, r.get::<bool>(1)?, r.get::<String>(2)?)),
        )
        .expect("inspect")
        .map(|(original, accepted, post)| {
            assert_eq!(original, c.canonical());
            (accepted, post)
        })
    }
    fn commit(&mut self, c: &Command) -> (bool, String) {
        let tx = weaver_ledger::persistence::begin(&mut self.0).expect("floor CAS");
        if let Some(original) = Self::inspect_at(&tx, c) {
            return original;
        }
        let frozen: String = weaver_ledger::persistence::one(
            &tx,
            "SELECT command FROM pending WHERE id=?1",
            weaver_ledger::persistence::params![c.id.to_owned()],
            |r| r.get(0),
        )
        .expect("must prepare");
        assert_eq!(frozen, c.canonical());
        let duplicate: bool = weaver_ledger::persistence::one(
            &tx,
            "SELECT EXISTS(SELECT 1 FROM prefix WHERE kind=?1 AND k=?2)",
            weaver_ledger::persistence::params![(c.kind).to_owned(), (c.key).to_owned()],
            |r| r.get(0),
        )
        .expect("logical uniqueness");
        let consumed: bool = weaver_ledger::persistence::one(
            &tx,
            "SELECT EXISTS(SELECT 1 FROM prefix WHERE kind=1 AND k=?1)",
            weaver_ledger::persistence::params![c.key.to_owned()],
            |r| r.get(0),
        )
        .expect("original consumption");
        let accepted = c.before == cut(&tx)
            && c.epoch == epoch(&tx)
            && (0..4).contains(&c.kind)
            && !(matches!(c.kind, 1 | 2) && duplicate)
            && (c.kind != 2 || consumed);
        if accepted {
            weaver_ledger::persistence::exec(
                &tx,
                "INSERT INTO prefix(kind,k,body) VALUES(?1,?2,?3)",
                weaver_ledger::persistence::params![
                    (c.kind).to_owned(),
                    (c.key).to_owned(),
                    (c.canonical()).to_owned()
                ],
            )
            .expect("full record");
        }
        let post = cut(&tx);
        weaver_ledger::persistence::exec(
            &tx,
            "INSERT INTO outcomes VALUES(?1,?2,?3,?4)",
            weaver_ledger::persistence::params![
                (c.id).to_owned(),
                (c.canonical()).to_owned(),
                (accepted).to_owned(),
                (post).to_owned()
            ],
        )
        .expect("immutable decision");
        tx.commit().expect("durable result before reply");
        (accepted, post)
    }
    fn rotate(&self) {
        weaver_ledger::persistence::exec(&self.0, "UPDATE owner SET epoch=epoch+1", ())
            .expect("durable fence");
    }
    fn repair(&self, projection: &Path) {
        let mut local = Session::open(projection).expect("projection");
        weaver_ledger::persistence::script(&local, "CREATE TABLE IF NOT EXISTS prefix(ordinal INTEGER PRIMARY KEY,kind INTEGER,k TEXT,body TEXT);").expect("projection schema");
        let tx = weaver_ledger::persistence::begin(&mut local).expect("projection atomic replace");
        weaver_ledger::persistence::exec(&tx, "DELETE FROM prefix", ())
            .expect("replace projection");
        for row in weaver_ledger::persistence::read_all(
            &self.0,
            "SELECT ordinal,kind,k,body FROM prefix ORDER BY ordinal",
            (),
            |r| {
                Ok((
                    r.get::<i64>(0)?,
                    r.get::<i64>(1)?,
                    r.get::<String>(2)?,
                    r.get::<String>(3)?,
                ))
            },
        )
        .expect("source records")
        {
            let (ordinal, kind, key, body) = row;
            weaver_ledger::persistence::exec(
                &tx,
                "INSERT INTO prefix VALUES(?1,?2,?3,?4)",
                weaver_ledger::persistence::params![
                    (ordinal).to_owned(),
                    (kind).to_owned(),
                    (key).to_owned(),
                    (body).to_owned()
                ],
            )
            .expect("repair full body");
        }
        tx.commit().expect("projection durable");
    }
    fn qualified(&self, projection: &Path, observed_epoch: i64) -> bool {
        observed_epoch == epoch(&self.0)
            && !unknown(&self.0)
            && cut(&weaver_ledger::persistence::Session::open(projection).expect("projection"))
                == cut(&self.0)
    }
    // Independent transport owner, never a permit returned to the worker. Burn
    // commits first; a second deciding transaction rechecks before the callback.
    // A crash after burn may omit a send, and must retain the original hold.
    fn send(
        &mut self,
        projection: &Path,
        observed_epoch: i64,
        key: &str,
        send: impl FnOnce(),
    ) -> bool {
        self.send_interleaved(projection, observed_epoch, key, |_| {}, send)
    }
    fn send_interleaved(
        &mut self,
        projection: &Path,
        observed_epoch: i64,
        key: &str,
        after_burn: impl FnOnce(&weaver_ledger::persistence::driver::Connection),
        send: impl FnOnce(),
    ) -> bool {
        let observed_cut =
            cut(&weaver_ledger::persistence::Session::open(projection)
                .expect("observed projection"));
        self.send_bound(
            projection,
            observed_epoch,
            &observed_cut,
            key,
            after_burn,
            send,
        )
    }
    fn send_bound(
        &mut self,
        projection: &Path,
        observed_epoch: i64,
        observed_cut: &str,
        key: &str,
        after_burn: impl FnOnce(&weaver_ledger::persistence::driver::Connection),
        send: impl FnOnce(),
    ) -> bool {
        self.send_bound_record(
            (projection, observed_epoch, observed_cut, key),
            None,
            after_burn,
            send,
        )
    }
    fn send_bound_record(
        &mut self,
        original: (&Path, i64, &str, &str),
        receipt: Option<&ProviderReceipt>,
        after_burn: impl FnOnce(&weaver_ledger::persistence::driver::Connection),
        send: impl FnOnce(),
    ) -> bool {
        let (projection, observed_epoch, observed_cut, key) = original;
        let tx = weaver_ledger::persistence::begin(&mut self.0).expect("burn CAS");
        let current = epoch(&tx) == observed_epoch
            && cut(&tx) == observed_cut
            && !unknown(&tx)
            && cut(&tx)
                == cut(&weaver_ledger::persistence::Session::open(projection).expect("projection"));
        let consumed: bool = weaver_ledger::persistence::one(
            &tx,
            "SELECT EXISTS(SELECT 1 FROM prefix WHERE kind=1 AND k=?1)",
            weaver_ledger::persistence::params![(key).to_owned()],
            |r| r.get(0),
        )
        .expect("spent record");
        if !current || !consumed {
            return false;
        }
        if let Some(receipt) = receipt {
            let already_recorded: bool = weaver_ledger::persistence::one(
                &tx,
                "SELECT EXISTS(SELECT 1 FROM prefix WHERE kind=4 AND k=?1)",
                weaver_ledger::persistence::params![(key).to_owned()],
                |row| row.get(0),
            )
            .expect("original admission lookup");
            if already_recorded
                || format!("{}/{}", receipt.family, receipt.node) != key
                || receipt.state != ProviderState::Unknown
            {
                return false;
            }
        }
        if weaver_ledger::persistence::exec(
            &tx,
            "INSERT OR IGNORE INTO burned VALUES(?1)",
            weaver_ledger::persistence::params![(key).to_owned()],
        )
        .expect("one use")
            != 1
        {
            return false;
        }
        if let Some(receipt) = receipt {
            let body = serde_json::to_string(&(SCOPE, key, receipt))
                .expect("canonical admission/exposure body");
            if weaver_ledger::persistence::exec(
                &tx,
                "INSERT INTO prefix(kind,k,body) VALUES(4,?1,?2)",
                weaver_ledger::persistence::params![(key).to_owned(), (body).to_owned()],
            )
            .is_err()
            {
                return false; // Dropping the transaction also rolls back burned.
            }
        }
        let expected = cut(&tx);
        tx.commit().expect("burn durable");
        after_burn(&self.0);
        let tx = weaver_ledger::persistence::begin(&mut self.0).expect("final admission");
        if epoch(&tx) != observed_epoch || cut(&tx) != expected || unknown(&tx) {
            return false;
        }
        send();
        tx.commit().expect("bounded callback leaves deciding lock");
        true
    }
}

#[test]
fn commit_floor_lost_reply_and_partial_projection_recover_all_four_bodies() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("authority.db");
    let projection = temp.path().join("projection.db");
    let mut floor = Floor::open(&path);
    let mut commands = Vec::new();
    for (id, kind) in [
        ("publication", 0),
        ("consume", 1),
        ("application", 2),
        ("history", 3),
    ] {
        let c = floor.command(id, kind, "original-claim");
        floor.stage(&c);
        assert!(floor.commit(&c).0);
        commands.push(c);
    }
    let committed = cut(&floor.0);
    drop(floor); // reply is lost; no projection was installed
    let mut recovered = Floor::open(&path);
    for c in &commands {
        assert!(recovered.inspect(c).expect("original decision").0);
    }
    assert_eq!(
        recovered.commit(&commands[1]).1,
        commands[2].before,
        "historical outcome cannot rebase"
    );
    recovered.repair(&projection);
    assert!(recovered.qualified(&projection, 0));
    let local = Session::open(&projection).expect("local");
    weaver_ledger::persistence::exec(&local, "DELETE FROM prefix WHERE kind=3", ())
        .expect("partial application");
    assert!(!recovered.qualified(&projection, 0));
    recovered.repair(&projection);
    weaver_ledger::persistence::exec(
        &local,
        "UPDATE prefix SET body='same-length-wrong-body' WHERE kind=2",
        (),
    )
    .expect("body substitution");
    assert!(!recovered.qualified(&projection, 0));
    recovered.repair(&projection);
    assert_eq!(cut(&local), committed);
    assert!(recovered.qualified(&projection, 0));
}

#[test]
fn commit_floor_absence_is_unknown_until_late_commit_or_fenced_rejection() {
    let temp = tempfile::tempdir().expect("temp");
    let mut floor = Floor::open(&temp.path().join("authority.db"));
    let projection = temp.path().join("projection.db");
    floor.repair(&projection);
    let late = floor.command("late", 1, "original-claim");
    floor.stage(&late);
    assert!(floor.inspect(&late).is_none());
    assert!(!floor.qualified(&projection, 0));
    assert!(
        floor.commit(&late).0,
        "an absent read cannot cancel a delayed commit"
    );
    let stale = floor.command("stale", 3, "history");
    floor.stage(&stale);
    floor.rotate();
    assert!(
        !floor.commit(&stale).0,
        "old epoch receives a durable rejection"
    );
    floor.repair(&projection);
    assert!(floor.qualified(&projection, 1));
    assert!(
        !floor.commit(&stale).0,
        "replay cannot rebase rejected intent"
    );
    assert!(
        !floor.qualified(&projection, 0),
        "cached old activation is not a permit"
    );
}

#[test]
fn commit_floor_stale_parent_and_new_ids_cannot_reconsume_original_claim() {
    let temp = tempfile::tempdir().expect("temp");
    let mut floor = Floor::open(&temp.path().join("authority.db"));
    let first = floor.command("first", 1, "original-claim");
    let stale = floor.command("stale", 1, "original-claim");
    floor.stage(&first);
    floor.stage(&stale);
    assert!(floor.commit(&first).0);
    assert!(!floor.commit(&stale).0);
    let duplicate = floor.command("fresh-nonce", 1, "original-claim");
    floor.stage(&duplicate);
    assert!(
        !floor.commit(&duplicate).0,
        "new ID/current parent cannot reset original claim"
    );
    let application = floor.command("application", 2, "original-claim");
    floor.stage(&application);
    assert!(floor.commit(&application).0);
    let repeated = floor.command("fresh-application-id", 2, "original-claim");
    floor.stage(&repeated);
    assert!(!floor.commit(&repeated).0);
}

#[test]
fn commit_floor_survives_gateway_restore_and_blocks_duplicate_real_dispatch() {
    let temp = tempfile::tempdir().expect("temp");
    let gateway = temp.path().join("gateway.db");
    let snapshot = temp.path().join("gateway-before-consume.db");
    let projection = temp.path().join("projection.db");
    let floor_path = temp.path().join("authority.db");
    let (mut ledger, plan) = super::fixture(&gateway);
    ledger
        .enqueue_provider(&plan)
        .expect("original reservation");
    ledger.close().expect("closed snapshot source");
    crate::snapshot::copy_closed(&gateway, &snapshot).expect("snapshot");
    let mut floor = Floor::open(&floor_path);
    let command = floor.command("consume", 1, "f/infer");
    floor.stage(&command);
    assert!(floor.commit(&command).0);
    floor.repair(&projection);
    let mut calls = 0;
    for restore in [false, true, true] {
        if restore {
            crate::snapshot::copy_closed(&snapshot, &gateway).expect("restore only gateway");
        }
        let mut ledger = Ledger::open(&gateway).expect("worker restart");
        let permit = ledger
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .expect("local state may forget consumption");
        let admitted = floor.send(&projection, 0, "f/infer", || {
            ledger
                .dispatch_provider(&permit, || {
                    calls += 1;
                    Ok(())
                })
                .expect("actual Ledger final callback");
        });
        assert_eq!(admitted, !restore);
        assert_eq!(ledger.held("f").expect("unknown hold"), 4);
        ledger.close().expect("close before restoring");
        drop(floor);
        floor = Floor::open(&floor_path); // service restart keeps committed burns
    }
    assert_eq!(calls, 1);
    floor.rotate();
    assert!(
        !floor.send(&projection, 0, "f/infer", || calls += 1),
        "old worker's read cannot survive the fence"
    );
    assert_eq!(calls, 1);
}

// Expected counterexample: losing the independent burn store together with the
// gateway defeats this reference envelope even when all four prefix bytes match.
// This is not a deployed authority or an attestation of failure-domain independence.
#[test]
fn identical_prefix_after_whole_store_restore_can_replay_dispatch_counterexample() {
    let temp = tempfile::tempdir().expect("directory");
    let gateway = temp.path().join("gateway.db");
    let gateway_snapshot = temp.path().join("gateway-snapshot.db");
    let floor_path = temp.path().join("authority.db");
    let floor_snapshot = temp.path().join("authority-snapshot.db");
    let projection = temp.path().join("projection.db");
    let (mut ledger, plan) = super::fixture(&gateway);
    ledger
        .enqueue_provider(&plan)
        .expect("original reservation");
    ledger.close().expect("closed gateway snapshot source");
    crate::snapshot::copy_closed(&gateway, &gateway_snapshot).expect("queued gateway snapshot");
    let mut floor = Floor::open(&floor_path);
    let command = floor.command("original-consumption", 1, "f/infer");
    floor.stage(&command);
    assert!(floor.commit(&command).0);
    floor.repair(&projection);
    let retained_prefix = cut(&floor.0);
    drop(floor);
    crate::snapshot::copy_closed(&floor_path, &floor_snapshot)
        .expect("closed pre-burn authority snapshot");
    let mut calls = 0;
    for restore_both in [false, true] {
        if restore_both {
            crate::snapshot::copy_closed(&gateway_snapshot, &gateway).expect("restore gateway");
            crate::snapshot::copy_closed(&floor_snapshot, &floor_path)
                .expect("restore authority and burned table");
        }
        floor = Floor::open(&floor_path);
        assert_eq!(
            cut(&floor.0),
            retained_prefix,
            "equal prefix does not retain burns"
        );
        assert!(
            floor.qualified(&projection, 0),
            "reference row/epoch equality still holds"
        );
        let mut worker = Ledger::open(&gateway).expect("restored worker");
        let permit = worker
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .expect("local consumption");
        assert!(
            floor.send(&projection, 0, "f/infer", || {
                worker
                    .dispatch_provider(&permit, || {
                        calls += 1;
                        Ok(())
                    })
                    .expect("real ledger callback");
            }),
            "expected gap: restoring both stores reopens the burn"
        );
        let receipt = worker
            .provider_receipt("f", "infer")
            .expect("receipt")
            .expect("original run");
        assert_eq!(
            (receipt.state, receipt.reserved, receipt.held),
            (weaver_contracts::ProviderState::Unknown, 4, 4)
        );
        worker.close().expect("close before snapshot restore");
        drop(floor);
    }
    assert_eq!(
        calls, 2,
        "expected duplicate: protected burn retention is a necessary premise"
    );
}

// A retained reference floor can prevent another send while the restored local
// budget projection has nevertheless forgotten the original unknown exposure.
#[test]
fn prefix_qualification_does_not_reconstruct_rolled_back_budget_counterexample() {
    let temp = tempfile::tempdir().expect("directory");
    let gateway = temp.path().join("gateway.db");
    let snapshot = temp.path().join("before-reservation.db");
    let projection = temp.path().join("projection.db");
    let floor_path = temp.path().join("authority.db");
    let (ledger, plan) = super::fixture(&gateway);
    ledger.close().expect("closed pre-reservation source");
    crate::snapshot::copy_closed(&gateway, &snapshot).expect("pre-reservation snapshot");
    let mut ledger = Ledger::open(&gateway).expect("live owner");
    ledger
        .enqueue_provider(&plan)
        .expect("original reservation");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("original consumption");
    let mut floor = Floor::open(&floor_path);
    let command = floor.command("original-consumption", 1, "f/infer");
    floor.stage(&command);
    assert!(floor.commit(&command).0);
    floor.repair(&projection);
    let mut calls = 0;
    assert!(floor.send(&projection, 0, "f/infer", || {
        ledger
            .dispatch_provider(&permit, || {
                calls += 1;
                Ok(())
            })
            .expect("original actual dispatch");
    }));
    assert_eq!(ledger.held("f").expect("original unknown exposure"), 4);
    ledger.close().expect("closed restore target");
    drop(floor);
    crate::snapshot::copy_closed(&snapshot, &gateway)
        .expect("restore only local budget and claim state");
    let recovered = Ledger::open(&gateway).expect("local snapshot recovery");
    floor = Floor::open(&floor_path);
    assert!(
        floor.qualified(&projection, 0),
        "reference qualification only compares its prefix/epoch"
    );
    assert_eq!(
        recovered.held("f").expect("rolled-back projection"),
        0,
        "expected missing budget projection, not proven unused funds"
    );
    assert!(
        recovered
            .provider_receipt("f", "infer")
            .expect("rolled-back receipt")
            .is_none()
    );
    assert!(
        !floor.send(&projection, 0, "f/infer", || calls += 1),
        "retained burn still prevents duplicate dispatch"
    );
    assert_eq!(calls, 1);
}

#[test]
fn commit_floor_competing_workers_serialize_and_recover_exact_shared_outcome() {
    use std::sync::{Arc, Barrier};
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("authority.db");
    let floor = Floor::open(&path);
    let command = floor.command("shared-id", 1, "claim");
    floor.stage(&command);
    let barrier = Arc::new(Barrier::new(2));
    let workers: Vec<_> = (0..2)
        .map(|_| {
            let barrier = barrier.clone();
            let path = path.clone();
            let command = command.clone();
            std::thread::spawn(move || {
                let mut worker = Floor::open(&path);
                barrier.wait();
                worker.commit(&command)
            })
        })
        .collect();
    let results: Vec<_> = workers
        .into_iter()
        .map(|w| w.join().expect("worker"))
        .collect();
    assert_eq!(results[0], results[1]);
    assert!(results[0].0);
    assert_eq!(
        weaver_ledger::persistence::one(&floor.0, "SELECT COUNT(*) FROM prefix", (), |r| r
            .get::<i64>(0))
        .expect("prefix count"),
        1
    );
}

#[test]
fn commit_floor_fence_between_burn_and_send_omits_effect_without_refund() {
    let temp = tempfile::tempdir().expect("temp");
    let gateway = temp.path().join("gateway.db");
    let (mut ledger, plan) = super::fixture(&gateway);
    ledger.enqueue_provider(&plan).expect("original hold");
    let mut floor = Floor::open(&temp.path().join("authority.db"));
    let projection = temp.path().join("projection.db");
    let c = floor.command("consume", 1, "f/infer");
    floor.stage(&c);
    assert!(floor.commit(&c).0);
    floor.repair(&projection);
    let mut calls = 0;
    assert!(!floor.send_interleaved(
        &projection,
        0,
        "f/infer",
        |db| {
            weaver_ledger::persistence::exec(db, "UPDATE owner SET epoch=epoch+1", ())
                .expect("concurrent fence");
        },
        || calls += 1
    ));
    floor.repair(&projection);
    assert!(
        !floor.send(&projection, 1, "f/infer", || calls += 1),
        "fresh epoch cannot repeat an ambiguous burn"
    );
    assert_eq!(calls, 0);
    assert_eq!(ledger.held("f").expect("unknown original hold"), 4);
}
