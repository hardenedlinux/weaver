//! Test-build observations only. No observer, environment switch or fault pause
//! is compiled into a production server. Pending is observed by polling the real
//! reserve_owned future, not inferred from sleep or an unchanged receipt count.
use super::Output;
use crate::pb;
use crate::test_fixtures as fixtures;
use std::{
    future::{Future, poll_fn},
    os::unix::net::UnixDatagram,
    sync::{
        OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    task::Poll,
    time::Duration,
};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use weaver_contracts::ProviderEvent;
use weaver_execution::ProviderOutput;
use weaver_ledger::Ledger;
type FrameMessage = Result<pb::ProviderFrame, tonic::Status>;
type QueueSender = mpsc::Sender<FrameMessage>;
type QueueReceiver = mpsc::Receiver<FrameMessage>;

struct Observer {
    socket: UnixDatagram,
    next: AtomicU64,
    waited: AtomicBool,
    pause: bool,
    paused: AtomicBool,
}
static OBSERVER: OnceLock<Observer> = OnceLock::new();
impl Observer {
    fn record(&self, phase: &str, id: u64, first: u64, rows: usize) {
        let event = format!("{phase} {id} {first} {rows}");
        self.socket
            .send(event.as_bytes())
            .expect("test observation delivery");
    }
}
pub(super) async fn observe<F: Future>(future: F) -> F::Output {
    let Some(observer) = OBSERVER.get() else {
        return future.await;
    };
    let id = observer.next.fetch_add(1, Ordering::SeqCst);
    let mut future = std::pin::pin!(future);
    let mut reported = false;
    poll_fn(|cx| match future.as_mut().poll(cx) {
        Poll::Pending => {
            if !reported {
                observer.waited.store(true, Ordering::SeqCst);
                observer.record("pending", id, 0, 0);
                reported = true;
            }
            Poll::Pending
        }
        Poll::Ready(result) => {
            observer.record("ready", id, 0, 0);
            Poll::Ready(result)
        }
    })
    .await
}
pub(super) fn enqueued(events: &[ProviderEvent]) {
    let Some(observer) = OBSERVER.get() else {
        return;
    };
    let first = events.first().expect("nonempty guarded batch").sequence;
    observer.record("enqueued", 0, first, events.len());
    if observer.pause
        && observer.waited.load(Ordering::SeqCst)
        && !observer.paused.swap(true, Ordering::SeqCst)
    {
        observer.record("fault-window", 0, first, events.len());
        // This bounded test-only pause exposes enqueue-before-commit. The Go
        // fault test must crash the process here, never turn a timeout into pass.
        std::thread::park_timeout(Duration::from_secs(3));
        panic!("enqueue/commit fault window was not consumed by the test");
    }
}

pub(super) fn cancelled() {
    if let Some(observer) = OBSERVER.get() {
        observer.record("cancelled", observer.next.load(Ordering::SeqCst) - 1, 0, 0);
    }
}

pub(super) fn expired() {
    if let Some(observer) = OBSERVER.get() {
        observer.record("expired", observer.next.load(Ordering::SeqCst) - 1, 0, 0);
    }
}

#[test]
#[ignore = "Go integration starts this test-only server with private observation custody"]
fn serve_observed_gateway() {
    let path = std::env::var("WEAVER_TEST_FLOW_EVENTS").expect("test observation socket");
    let socket = UnixDatagram::unbound().expect("observer socket");
    socket.connect(path).expect("observer peer");
    socket
        .set_nonblocking(true)
        .expect("bounded observation delivery");
    assert!(
        OBSERVER
            .set(Observer {
                socket,
                next: AtomicU64::new(1),
                waited: AtomicBool::new(false),
                pause: std::env::var_os("WEAVER_TEST_PAUSE_AFTER_WAITED_ENQUEUE").is_some(),
                paused: AtomicBool::new(false)
            })
            .is_ok()
    );
    crate::entrypoint::run().expect("observed server natural shutdown");
}

fn full_output() -> (Output, QueueReceiver, QueueSender) {
    let (sender, receiver) = mpsc::channel(2);
    for _ in 0..2 {
        sender
            .try_send(Ok(pb::ProviderFrame::default()))
            .expect("fill actual queue");
    }
    (
        Output {
            telemetry: std::sync::Arc::new(weaver_telemetry::Metrics::default()),
            sender: sender.clone(),
            cancelled: CancellationToken::new(),
            shutdown: CancellationToken::new(),
            runtime: tokio::runtime::Handle::current(),
            arrow: true,
        },
        receiver,
        sender,
    )
}
async fn wait_for_reservation(sender: &QueueSender) {
    tokio::time::timeout(Duration::from_millis(500), async {
        while sender.strong_count() < 3 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("actual reserve future entered within original one-second gate");
    assert_eq!(sender.capacity(), 0);
}
fn prepared_ledger(path: &std::path::Path) -> (Ledger, weaver_ledger::ProviderDispatch) {
    let mut ledger = Ledger::open(path).expect("ledger");
    let schema = include_str!("../../../../prod/policies/provider/schema.json");
    ledger
        .publish_typed(None, "permit(principal,action,resource);", schema, 1)
        .expect("policy");
    let (task, plan) = fixtures::task_plan(16, "https://provider.invalid/v1/chat/completions");
    ledger.register_task(&task).expect("original task");
    ledger.enqueue_provider(&plan).expect("queue original");
    let permit = ledger
        .consume_provider("f", "infer", &["primary".into()].into())
        .expect("consume");
    ledger
        .dispatch_provider(&permit, || ())
        .expect("burn dispatch; no network in this unit check");
    (ledger, permit)
}

#[tokio::test(flavor = "multi_thread")]
async fn waiting_capacity_does_not_hold_sql_or_authorize_after_publication() {
    let directory = tempfile::tempdir().expect("temp");
    let path = directory.path().join("ledger.db");
    let (mut ledger, permit) = prepared_ledger(&path);
    let (mut output, mut receiver, sender) = full_output();
    let task = tokio::task::spawn_blocking(move || output.reserve());
    wait_for_reservation(&sender).await;
    let schema = include_str!("../../../../prod/policies/provider/schema.json");
    ledger
        .publish_typed(Some(0), "forbid(principal,action,resource);", schema, 2)
        .expect("publication while capacity is blocked");
    receiver
        .try_recv()
        .expect("return capacity after committed revoke")
        .expect("seed frame");
    let slot = task
        .await
        .expect("worker")
        .expect("capacity returned without widening timeout");
    assert!(
        ledger
            .prepare_provider_release(&permit, "blocked-batch", "arrow", 2)
            .is_err()
    );
    drop(slot);
    assert_eq!(ledger.held("f").expect("hold"), 4);
}

#[tokio::test(flavor = "multi_thread")]
async fn pending_range_history_created_during_capacity_wait_cannot_be_replayed() {
    let directory = tempfile::tempdir().expect("temp");
    let path = directory.path().join("ledger.db");
    let (mut ledger, permit) = prepared_ledger(&path);
    let (mut output, mut receiver, sender) = full_output();
    let task = tokio::task::spawn_blocking(move || output.reserve());
    wait_for_reservation(&sender).await;
    let pending = ledger
        .prepare_provider_release(&permit, "prior-unknown", "arrow", 2)
        .expect("durable original range history");
    drop(pending);
    receiver
        .try_recv()
        .expect("return capacity")
        .expect("seed frame");
    drop(task.await.expect("worker").expect("capacity"));
    assert!(
        ledger
            .prepare_provider_release(&permit, "new-label", "arrow", 2)
            .is_err()
    );
    ledger.close().expect("close");
    let mut recovered = Ledger::open(&path).expect("restart");
    assert!(
        recovered
            .prepare_provider_release(&permit, "fresh-session", "arrow", 2)
            .is_err()
    );
    let receipt = recovered
        .provider_receipt("f", "infer")
        .expect("receipt")
        .expect("original");
    assert_eq!(receipt.events, 2);
    assert_eq!(receipt.held, 4);
}

#[tokio::test(flavor = "multi_thread")]
async fn cancellation_interrupts_actual_capacity_wait_without_refund() {
    let directory = tempfile::tempdir().expect("temp");
    let (ledger, _permit) = prepared_ledger(&directory.path().join("ledger.db"));
    let (mut output, _receiver, sender) = full_output();
    let cancelled = output.cancelled.clone();
    let task = tokio::task::spawn_blocking(move || output.reserve());
    wait_for_reservation(&sender).await;
    cancelled.cancel();
    assert!(task.await.expect("worker").is_err());
    assert_eq!(ledger.held("f").expect("hold"), 4);
}
