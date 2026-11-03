// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! TCP ordering witnesses for the independent floor reference. This is not the
//! production TLS transport, gRPC authentication or a Kubernetes fencing test.
use super::{Floor, cut, epoch};
use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};
use weaver_ledger::persistence::Session;

const WAIT: Duration = Duration::from_secs(3);
const KEY: &str = "original-claim";
const SECRET: &[u8] = b"owner-only-test-credential\n";

#[derive(Clone)]
struct Observation {
    cut: String,
    epoch: i64,
}
impl Observation {
    fn current(floor: &Floor) -> Self {
        Self {
            cut: cut(&floor.0),
            epoch: epoch(&floor.0),
        }
    }
}
#[derive(Debug, PartialEq, Eq)]
enum Reply {
    Denied,
    Unknown,
}
struct Request {
    observation: Observation,
    reply: mpsc::Sender<Reply>,
}
// The worker-facing request has no secret, endpoint, raw socket or send callback.
struct Worker(mpsc::SyncSender<Request>);
impl Worker {
    fn submit(&self, observation: Observation) -> Reply {
        let (reply, rx) = mpsc::channel();
        self.0
            .send(Request { observation, reply })
            .expect("proposal");
        rx.recv_timeout(WAIT).expect("bounded owner reply")
    }
    fn lose_reply(&self, observation: Observation) {
        let (reply, rx) = mpsc::channel();
        drop(rx);
        self.0
            .send(Request { observation, reply })
            .expect("proposal before lost reply");
    }
}
fn spawn_owner(
    authority: PathBuf,
    projection: PathBuf,
    peer: SocketAddr,
) -> (Worker, thread::JoinHandle<()>) {
    let (tx, rx) = mpsc::sync_channel::<Request>(4);
    let owner = thread::spawn(move || {
        let mut floor = Floor::open(&authority);
        // Test installer provisions the credential here, never in a request.
        let credential = SECRET.to_vec();
        while let Ok(request) = rx.recv() {
            let admitted = floor.send_bound(
                &projection,
                request.observation.epoch,
                &request.observation.cut,
                KEY,
                |_| {},
                || {
                    let mut stream = TcpStream::connect_timeout(&peer, WAIT).expect("owner socket");
                    stream.set_read_timeout(Some(WAIT)).expect("read bound");
                    stream.set_write_timeout(Some(WAIT)).expect("write bound");
                    stream
                        .write_all(&credential)
                        .expect("partial request already external");
                    // The peer closes after the prefix: no terminal usage follows.
                    let mut response = [0_u8; 1];
                    assert!(stream.read_exact(&mut response).is_err());
                },
            );
            let _ = request.reply.send(if admitted {
                Reply::Unknown
            } else {
                Reply::Denied
            });
        }
    });
    (Worker(tx), owner)
}
fn consumed(path: &Path, projection: &Path) -> Floor {
    let mut floor = Floor::open(path);
    let c = floor.command("consume", 1, KEY);
    floor.stage(&c);
    assert!(floor.commit(&c).0);
    floor.repair(projection);
    floor
}

#[test]
fn queued_old_cut_and_lost_owner_reply_cannot_rebase_or_repeat_socket_admission() {
    let temp = tempfile::tempdir().expect("temp");
    let authority = temp.path().join("authority.db");
    let projection = temp.path().join("projection.db");
    let mut floor = consumed(&authority, &projection);
    let old = Observation::current(&floor);
    let publication = floor.command("changed-publication", 0, KEY);
    floor.stage(&publication);
    assert!(floor.commit(&publication).0);
    floor.repair(&projection);
    let current = Observation::current(&floor);
    let peer = TcpListener::bind("127.0.0.1:0").expect("peer");
    let address = peer.local_addr().expect("address");
    let calls = Arc::new(AtomicUsize::new(0));
    let count = calls.clone();
    let provider = thread::spawn(move || {
        // Nonblocking accept is bounded without sleeps or a widened watchdog.
        peer.set_nonblocking(true).expect("nonblocking listener");
        let deadline = std::time::Instant::now() + WAIT;
        let (mut socket, _) = loop {
            match peer.accept() {
                Ok(value) => break value,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        std::time::Instant::now() < deadline,
                        "provider acceptance deadline"
                    );
                    thread::yield_now();
                }
                Err(e) => panic!("peer accept: {e}"),
            }
        };
        socket
            .set_nonblocking(false)
            .expect("bounded blocking peer read");
        socket
            .set_read_timeout(Some(WAIT))
            .expect("peer read bound");
        let mut prefix = vec![0; SECRET.len()];
        socket.read_exact(&mut prefix).expect("partial request");
        assert_eq!(prefix, SECRET);
        count.fetch_add(1, Ordering::SeqCst);
        // Drop without response; never reinterpret this as no execution.
    });
    let (worker, owner) = spawn_owner(authority.clone(), projection.clone(), address);
    assert_eq!(
        worker.submit(old.clone()),
        Reply::Denied,
        "projection repair cannot rebase an old proposal"
    );
    worker.lose_reply(current.clone());
    assert_eq!(
        worker.submit(current.clone()),
        Reply::Denied,
        "lost reply cannot repeat the burned attempt"
    );
    drop(worker);
    owner.join().expect("actual reference owner terminated");
    provider.join().expect("provider");
    // Recreate worker state and the reference owner after confirmed thread exit.
    // This receipt establishes thread lifetime only, not OS/node quiescence.
    floor.rotate();
    floor.repair(&projection);
    let (worker, restarted) = spawn_owner(authority, projection, address);
    assert_eq!(worker.submit(old), Reply::Denied);
    assert_eq!(worker.submit(current), Reply::Denied);
    assert_eq!(
        worker.submit(Observation::current(&floor)),
        Reply::Denied,
        "new incarnation cannot reconstruct an unknown burn"
    );
    drop(worker);
    restarted.join().expect("restarted owner terminated");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn floor_mutation_is_excluded_through_actual_tcp_write_admission() {
    let temp = tempfile::tempdir().expect("temp");
    let authority = temp.path().join("authority.db");
    let projection = temp.path().join("projection.db");
    let floor = consumed(&authority, &projection);
    let observation = Observation::current(&floor);
    let (entered, entered_rx) = mpsc::channel();
    let (release, release_rx) = mpsc::channel();
    let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
    let address = listener.local_addr().expect("address");
    let owner_path = authority.clone();
    let owner_projection = projection.clone();
    let owner = thread::spawn(move || {
        let mut floor = Floor::open(&owner_path);
        assert!(floor.send_bound(
            &owner_projection,
            observation.epoch,
            &observation.cut,
            KEY,
            |_| {},
            || {
                let mut socket = TcpStream::connect_timeout(&address, WAIT).expect("socket");
                socket.set_write_timeout(Some(WAIT)).expect("write bound");
                socket.write_all(b"first").expect("first actual write");
                entered
                    .send(())
                    .expect("entered transport under deciding lock");
                release_rx
                    .recv_timeout(WAIT)
                    .expect("release bounded transport");
                socket.write_all(b"last").expect("last actual write");
            }
        ));
    });
    entered_rx
        .recv_timeout(WAIT)
        .expect("guarded transport entered");
    // Deterministic lock evidence, rather than timing a racing thread or sleep.
    let competing = Session::open(&authority).expect("competing authority mutation");
    competing
        .busy_timeout(Duration::ZERO)
        .expect("nonblocking conflict observation");
    let conflict =
        weaver_ledger::persistence::exec(&competing, "UPDATE owner SET epoch=epoch+1", ())
            .expect_err("no commit inside guarded transport");
    assert!(matches!(
        conflict,
        weaver_ledger::persistence::Error::Busy(_)
            | weaver_ledger::persistence::Error::BusySnapshot(_)
    ));
    release.send(()).expect("finish bounded write");
    owner.join().expect("owner");
    let (mut socket, _) = listener.accept().expect("already queued connection");
    socket.set_read_timeout(Some(WAIT)).expect("read bound");
    let mut bytes = Vec::new();
    socket.read_to_end(&mut bytes).expect("actual bytes");
    assert_eq!(bytes, b"firstlast");
    weaver_ledger::persistence::exec(&competing, "UPDATE owner SET epoch=epoch+1", ())
        .expect("mutation after admission completes");
    assert!(
        !floor.qualified(&projection, 0),
        "old image loses qualification after publication fence"
    );
}

#[test]
fn old_exported_socket_bypasses_floor_epoch_counterexample() {
    let temp = tempfile::tempdir().expect("temp");
    let floor = consumed(
        &temp.path().join("authority.db"),
        &temp.path().join("projection.db"),
    );
    let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
    let mut escaped = TcpStream::connect_timeout(&listener.local_addr().expect("address"), WAIT)
        .expect("old socket");
    let (mut peer, _) = listener.accept().expect("old authenticated-path surrogate");
    escaped.set_write_timeout(Some(WAIT)).expect("write bound");
    peer.set_read_timeout(Some(WAIT)).expect("read bound");
    floor.rotate(); // No mechanism here revoked this raw FD's actual IO rights.
    escaped
        .write_all(b"escaped")
        .expect("old FD remains writable after epoch advance");
    let mut bytes = [0_u8; 7];
    peer.read_exact(&mut bytes).expect("external bytes");
    assert_eq!(&bytes, b"escaped");
    let burns: i64 =
        weaver_ledger::persistence::one(&floor.0, "SELECT COUNT(*) FROM burned", (), |r| r.get(0))
            .expect("burns");
    assert_eq!(
        burns, 0,
        "expected unsafe witness: labels cannot mediate a leaked socket"
    );
}
