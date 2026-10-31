//! Executable protocol reference, not a deployed independent authority.
//! Two files only define this test's restore boundary; they do not establish
//! failure-domain independence. Domain payload validation stays with its owner.
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use std::{collections::BTreeSet, path::Path};
use weaver_ledger::Ledger;

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
struct Floor(Connection);
fn cut(db: &Connection) -> String {
    let mut query = db
        .prepare("SELECT kind,k,body FROM prefix ORDER BY ordinal")
        .expect("prefix query");
    let entries = query
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })
        .expect("read prefix")
        .collect::<Result<Vec<_>, _>>()
        .expect("complete prefix");
    serde_json::to_string(&entries).expect("canonical full prefix")
}
fn epoch(db: &Connection) -> i64 {
    db.query_row("SELECT epoch FROM owner", [], |r| r.get(0))
        .expect("epoch")
}
fn unknown(db: &Connection) -> bool {
    db.query_row("SELECT EXISTS(SELECT 1 FROM pending p LEFT JOIN outcomes o ON p.id=o.id WHERE o.id IS NULL)",[],|r|r.get(0)).expect("pending outcomes")
}
impl Floor {
    fn open(path: &Path) -> Self {
        let db = Connection::open(path).expect("authority store");
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
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
        self.0
            .execute(
                "INSERT OR IGNORE INTO pending VALUES(?1,?2)",
                params![c.id, c.canonical()],
            )
            .expect("durable prepare");
        let frozen: String = self
            .0
            .query_row("SELECT command FROM pending WHERE id=?1", [&c.id], |r| {
                r.get(0)
            })
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
    fn inspect_at(db: &Connection, c: &Command) -> Option<(bool, String)> {
        db.query_row(
            "SELECT command,accepted,post FROM outcomes WHERE id=?1",
            [&c.id],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, bool>(1)?,
                    r.get::<_, String>(2)?,
                ))
            },
        )
        .optional()
        .expect("inspect")
        .map(|(original, accepted, post)| {
            assert_eq!(original, c.canonical());
            (accepted, post)
        })
    }
    fn commit(&mut self, c: &Command) -> (bool, String) {
        let tx = self
            .0
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .expect("floor CAS");
        if let Some(original) = Self::inspect_at(&tx, c) {
            return original;
        }
        let frozen: String = tx
            .query_row("SELECT command FROM pending WHERE id=?1", [&c.id], |r| {
                r.get(0)
            })
            .expect("must prepare");
        assert_eq!(frozen, c.canonical());
        let duplicate: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM prefix WHERE kind=?1 AND k=?2)",
                params![c.kind, c.key],
                |r| r.get(0),
            )
            .expect("logical uniqueness");
        let consumed: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM prefix WHERE kind=1 AND k=?1)",
                [&c.key],
                |r| r.get(0),
            )
            .expect("original consumption");
        let accepted = c.before == cut(&tx)
            && c.epoch == epoch(&tx)
            && (0..4).contains(&c.kind)
            && !(matches!(c.kind, 1 | 2) && duplicate)
            && (c.kind != 2 || consumed);
        if accepted {
            tx.execute(
                "INSERT INTO prefix(kind,k,body) VALUES(?1,?2,?3)",
                params![c.kind, c.key, c.canonical()],
            )
            .expect("full record");
        }
        let post = cut(&tx);
        tx.execute(
            "INSERT INTO outcomes VALUES(?1,?2,?3,?4)",
            params![c.id, c.canonical(), accepted, post],
        )
        .expect("immutable decision");
        tx.commit().expect("durable result before reply");
        (accepted, post)
    }
    fn rotate(&self) {
        self.0
            .execute("UPDATE owner SET epoch=epoch+1", [])
            .expect("durable fence");
    }
    fn repair(&self, projection: &Path) {
        let mut local = Connection::open(projection).expect("projection");
        local.execute_batch("CREATE TABLE IF NOT EXISTS prefix(ordinal INTEGER PRIMARY KEY,kind INTEGER,k TEXT,body TEXT);").expect("projection schema");
        let tx = local.transaction().expect("projection atomic replace");
        tx.execute("DELETE FROM prefix", [])
            .expect("replace projection");
        let mut query = self
            .0
            .prepare("SELECT ordinal,kind,k,body FROM prefix ORDER BY ordinal")
            .expect("source prefix");
        for row in query
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })
            .expect("source records")
        {
            let (ordinal, kind, key, body) = row.expect("complete source record");
            tx.execute(
                "INSERT INTO prefix VALUES(?1,?2,?3,?4)",
                params![ordinal, kind, key, body],
            )
            .expect("repair full body");
        }
        tx.commit().expect("projection durable");
    }
    fn qualified(&self, projection: &Path, observed_epoch: i64) -> bool {
        observed_epoch == epoch(&self.0)
            && !unknown(&self.0)
            && cut(&Connection::open(projection).expect("projection")) == cut(&self.0)
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
        after_burn: impl FnOnce(&Connection),
        send: impl FnOnce(),
    ) -> bool {
        let tx = self
            .0
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .expect("burn CAS");
        let current = epoch(&tx) == observed_epoch
            && !unknown(&tx)
            && cut(&tx) == cut(&Connection::open(projection).expect("projection"));
        let consumed: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM prefix WHERE kind=1 AND k=?1)",
                [key],
                |r| r.get(0),
            )
            .expect("spent record");
        if !current || !consumed {
            return false;
        }
        if tx
            .execute("INSERT OR IGNORE INTO burned VALUES(?1)", [key])
            .expect("one use")
            != 1
        {
            return false;
        }
        let expected = cut(&tx);
        tx.commit().expect("burn durable");
        after_burn(&self.0);
        let tx = self
            .0
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .expect("final admission");
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
    let local = Connection::open(&projection).expect("local");
    local
        .execute("DELETE FROM prefix WHERE kind=3", [])
        .expect("partial application");
    assert!(!recovered.qualified(&projection, 0));
    recovered.repair(&projection);
    local
        .execute(
            "UPDATE prefix SET body='same-length-wrong-body' WHERE kind=2",
            [],
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
    std::fs::copy(&gateway, &snapshot).expect("snapshot");
    let mut floor = Floor::open(&floor_path);
    let command = floor.command("consume", 1, "f/infer");
    floor.stage(&command);
    assert!(floor.commit(&command).0);
    floor.repair(&projection);
    let mut calls = 0;
    for restore in [false, true, true] {
        if restore {
            std::fs::copy(&snapshot, &gateway).expect("restore only gateway");
        }
        let mut ledger = Ledger::open(&gateway).expect("worker restart");
        let permit = ledger
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .expect("local state may forget consumption");
        let admitted = floor.send(&projection, 0, "f/infer", || {
            ledger
                .dispatch_provider(&permit, || calls += 1)
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
        floor
            .0
            .query_row("SELECT COUNT(*) FROM prefix", [], |r| r.get::<_, i64>(0))
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
            db.execute("UPDATE owner SET epoch=epoch+1", [])
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
