use crate::ServiceRuntime;
use std::{
    num::NonZeroUsize,
    sync::{Arc, mpsc},
    time::Duration,
};
use tokio::sync::{Semaphore, oneshot};
use weaver_contracts::Error;
use weaver_governance::{OwnedSource, SourceError};

fn budget() -> (Arc<Semaphore>, Arc<tokio::sync::OwnedSemaphorePermit>) {
    let permits = Arc::new(Semaphore::new(2));
    let permit = Arc::new(permits.clone().try_acquire_owned().expect("host permit"));
    (permits, permit)
}
fn capacity() -> NonZeroUsize {
    std::thread::available_parallelism().expect("host budget")
}
fn copy(source: &OwnedSource) -> Result<OwnedSource, SourceError> {
    OwnedSource::from_source(source.data().clone())
}
fn original() -> OwnedSource {
    let (task, plan) =
        crate::test_fixtures::task_plan(128, "https://provider.invalid/v1/chat/completions");
    OwnedSource::from_source(weaver_governance::SourceData {
        governance: weaver_governance::SourceSelection {
            schema: "agentic-ai-lab.loop-governor.v1".into(),
            family: task.family.clone(),
            open_nodes: task.nodes.clone(),
        },
        tasks: vec![task],
        plans: vec![plan],
        publication: weaver_contracts::Publication {
            operation_id: "source".into(),
            expected_revision: Some(0),
            fence: 1,
            policy: "forbid(principal,action,resource);".into(),
            schema: include_str!("../../../../prod/policies/provider/schema.json").into(),
        },
    })
    .expect("original source")
}
struct Cleanup(Option<oneshot::Sender<()>>);
impl Drop for Cleanup {
    fn drop(&mut self) {
        if let Some(sender) = self.0.take() {
            let _ = sender.send(());
        }
    }
}
struct Release(Option<mpsc::Sender<()>>);
impl Drop for Release {
    fn drop(&mut self) {
        if let Some(sender) = self.0.take() {
            let _ = sender.send(());
        }
    }
}
#[tokio::test]
async fn idle_owner_closes_with_shared_runtime_and_cleans_before_drain() {
    let runtime = ServiceRuntime::new();
    let (permits, slot) = budget();
    let (done, cleaned) = oneshot::channel();
    let owner = runtime
        .start_governance(slot, capacity(), move || {
            let cleanup = Cleanup(Some(done));
            let local = std::rc::Rc::new(std::cell::Cell::new(0));
            Ok(move |source: &OwnedSource| {
                let _keep = &cleanup;
                local.set(local.get() + 1);
                copy(source)
            })
        })
        .await
        .expect("initialized");
    assert_eq!(permits.available_permits(), 1);
    runtime.request_shutdown();
    assert!(runtime.closing());
    tokio::time::timeout(Duration::from_secs(3), runtime.drain())
        .await
        .expect("natural drain");
    cleaned.await.expect("compiler dropped before drain");
    assert_eq!(permits.available_permits(), 2);
    owner.finish().await.expect("worker joined");
}
#[tokio::test]
async fn abandoned_initialization_keeps_worker_tracked_until_natural_cleanup() {
    let runtime = ServiceRuntime::new();
    let (permits, slot) = budget();
    let (entered, started) = oneshot::channel();
    let (release, wait) = mpsc::channel();
    let release = Release(Some(release));
    let (done, cleaned) = oneshot::channel();
    let starting = runtime.clone();
    let task = tokio::spawn(async move {
        starting
            .start_governance(slot, capacity(), move || {
                let _ = entered.send(());
                wait.recv_timeout(Duration::from_secs(3))
                    .map_err(|_| Error::Conflict("factory not released"))?;
                let cleanup = Cleanup(Some(done));
                Ok(move |source: &OwnedSource| {
                    let _keep = &cleanup;
                    copy(source)
                })
            })
            .await
    });
    tokio::time::timeout(Duration::from_secs(3), started)
        .await
        .expect("factory start")
        .expect("started");
    task.abort();
    assert!(matches!(task.await, Err(error) if error.is_cancelled()));
    assert!(runtime.closing());
    assert_eq!(permits.available_permits(), 1);
    drop(release);
    tokio::time::timeout(Duration::from_secs(3), runtime.drain())
        .await
        .expect("tracked natural cleanup");
    cleaned.await.expect("compiler dropped");
    assert_eq!(permits.available_permits(), 2);
}
#[tokio::test]
async fn second_owner_is_refused_without_closing_installed_owner() {
    let runtime = ServiceRuntime::new();
    let (_, slot) = budget();
    let owner = runtime
        .start_governance(slot, capacity(), || Ok(copy))
        .await
        .expect("first owner");
    let (_, slot) = budget();
    assert!(
        runtime
            .start_governance(slot, capacity(), || Ok(copy))
            .await
            .is_err()
    );
    assert!(!runtime.closing());
    owner.finish().await.expect("finish");
    runtime.drain().await;
}
#[tokio::test]
async fn failed_initialization_is_terminal_and_releases_host_permit() {
    let runtime = ServiceRuntime::new();
    let (permits, slot) = budget();
    let result = runtime
        .start_governance(slot, capacity(), || {
            Err::<fn(&OwnedSource) -> Result<OwnedSource, SourceError>, _>(Error::Conflict(
                "rejected approved factory",
            ))
        })
        .await;
    assert!(result.is_err());
    assert!(runtime.closing());
    runtime.drain().await;
    assert_eq!(permits.available_permits(), 2);
}
#[tokio::test]
async fn late_initialization_cannot_activate_after_shared_close() {
    let runtime = ServiceRuntime::new();
    let (permits, slot) = budget();
    let (entered, started) = oneshot::channel();
    let (release, wait) = mpsc::channel();
    let release = Release(Some(release));
    let (done, cleaned) = oneshot::channel();
    let starting = runtime.clone();
    let task = tokio::spawn(async move {
        starting
            .start_governance(slot, capacity(), move || {
                let _ = entered.send(());
                wait.recv_timeout(Duration::from_secs(3))
                    .map_err(|_| Error::Conflict("factory not released"))?;
                let cleanup = Cleanup(Some(done));
                Ok(move |source: &OwnedSource| {
                    let _keep = &cleanup;
                    copy(source)
                })
            })
            .await
    });
    tokio::time::timeout(Duration::from_secs(3), started)
        .await
        .expect("factory start")
        .expect("started");
    runtime.request_shutdown();
    drop(release);
    assert!(task.await.expect("startup returned").is_err());
    cleaned.await.expect("compiler cleaned before rejection");
    runtime.drain().await;
    assert_eq!(permits.available_permits(), 2);
}
#[tokio::test]
async fn dropping_active_guard_fences_delivery_but_keeps_cleanup_tracked() {
    let runtime = ServiceRuntime::new();
    let (permits, slot) = budget();
    let (entered, started) = oneshot::channel();
    let (release, wait) = mpsc::channel();
    let release = Release(Some(release));
    let (done, cleaned) = oneshot::channel();
    let owner = runtime
        .start_governance(slot, capacity(), move || {
            let cleanup = Cleanup(Some(done));
            let mut entered = Some(entered);
            Ok(move |source: &OwnedSource| {
                let _keep = &cleanup;
                if let Some(entered) = entered.take() {
                    let _ = entered.send(());
                }
                wait.recv_timeout(Duration::from_secs(3))
                    .map_err(|_| SourceError::Scheme)?;
                copy(source)
            })
        })
        .await
        .expect("initialized");
    let job = owner.client().submit(original()).expect("source admitted");
    tokio::time::timeout(Duration::from_secs(3), started)
        .await
        .expect("call started")
        .expect("entered");
    drop(owner);
    assert!(runtime.closing());
    assert!(matches!(
        job.await,
        Err(weaver_governance::SourceJobError::Closed)
    ));
    assert_eq!(permits.available_permits(), 1);
    drop(release);
    tokio::time::timeout(Duration::from_secs(3), runtime.drain())
        .await
        .expect("natural cleanup");
    cleaned.await.expect("compiler destruction");
    assert_eq!(permits.available_permits(), 2);
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config {
        cases:32,rng_seed:proptest::test_runner::RngSeed::Fixed(293),..Default::default()
    })]
    #[test]
    fn shared_owner_schedules_preserve_cleanup_and_terminal_admission(
        events in proptest::collection::vec(0u8..6,1..24)
    ) {
        let executor=tokio::runtime::Builder::new_current_thread().enable_all().build().expect("test runtime");
        executor.block_on(async {
            let runtime=ServiceRuntime::new();let (permits,slot)=budget();
            let (done,mut cleaned)=oneshot::channel();
            let worker=runtime.start_governance(slot,capacity(),move|| {
                let cleanup=Cleanup(Some(done));
                let thread=std::thread::current().id();
                let local=std::rc::Rc::new(std::cell::Cell::new(0));
                Ok(move|source:&OwnedSource| {
                    let _keep=&cleanup;assert_eq!(std::thread::current().id(),thread);
                    local.set(local.get()+1);copy(source)
                })
            }).await.expect("approved factory");
            let client=worker.client();let mut worker=Some(worker);let mut jobs=Vec::new();
            let mut closed=false;
            for event in events {
                match event {
                    0 => match client.submit(original()) {
                        Ok(job) => {assert!(!closed);jobs.push(job)},
                        Err(weaver_governance::SourceJobError::Closed) => assert!(closed),
                        Err(weaver_governance::SourceJobError::Busy) => assert!(!closed),
                        Err(error) => panic!("unexpected scheduling error: {error}"),
                    },
                    1 => {drop(jobs.pop());},
                    2 => {runtime.request_shutdown();closed=true;},
                    3 => {drop(worker.take());closed=true;},
                    4 => {runtime.drain().await;closed=true;assert_eq!(permits.available_permits(),2);},
                    _ => if let Some(job)=jobs.pop() {
                        let result=job.await;
                        if closed {assert!(matches!(result,Err(weaver_governance::SourceJobError::Closed)));}
                        else {assert!(result.is_ok_and(|bound|bound.source().task().family=="f"));}
                    },
                }
            }
            runtime.drain().await;
            assert!(cleaned.try_recv().is_ok());assert_eq!(permits.available_permits(),2);
            if let Some(worker)=worker {worker.finish().await.expect("joined");}
            assert!(matches!(client.submit(original()),Err(weaver_governance::SourceJobError::Closed)));
        });
    }
}
