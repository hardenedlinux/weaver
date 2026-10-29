use super::RuntimeOwner;
use std::{future::Future, sync::Arc, task::Poll, time::Duration};
use tokio::sync::{Semaphore, oneshot};
use weaver_contracts::Error;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn detached_native_writer_keeps_slot_until_drain_acknowledges_completion() {
    let owner = RuntimeOwner::new();
    let slots = Arc::new(Semaphore::new(1));
    let slot = Arc::new(slots.clone().try_acquire_owned().expect("slot"));
    let (started_tx, started_rx) = oneshot::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let job = owner
        .spawn_blocking(slot, move |cancel| {
            let _ = started_tx.send(());
            release_rx
                .recv_timeout(Duration::from_secs(3))
                .map_err(|_| Error::Conflict("test writer not released"))?;
            assert!(cancel.is_cancelled());
            Ok(())
        })
        .expect("tracked job");
    tokio::time::timeout(Duration::from_secs(3), started_rx)
        .await
        .expect("start deadline")
        .expect("started");
    drop(job); // Simulate a disconnected HTTP caller, without aborting the writer.
    owner.request_shutdown();
    assert!(owner.closing());
    assert_eq!(slots.available_permits(), 0);
    let other = Arc::new(
        Arc::new(Semaphore::new(1))
            .try_acquire_owned()
            .expect("other slot"),
    );
    assert!(owner.spawn_blocking(other, |_| Ok(())).is_err());
    let mut drain = Box::pin(owner.drain());
    std::future::poll_fn(|cx| {
        assert!(matches!(drain.as_mut().poll(cx), Poll::Pending));
        Poll::Ready(())
    })
    .await;
    release_tx.send(()).expect("release");
    tokio::time::timeout(Duration::from_secs(3), drain)
        .await
        .expect("drain deadline");
    assert_eq!(slots.available_permits(), 1);
}

#[tokio::test]
async fn poisoned_admission_still_closes_and_drains() {
    let owner = RuntimeOwner::new();
    let inner = owner.inner.clone();
    let panicked = std::thread::spawn(move || {
        let _guard = inner.gate.lock().expect("gate");
        panic!("negative control: admission owner panicked");
    })
    .join();
    assert!(panicked.is_err());
    owner.request_shutdown();
    assert!(owner.closing());
    tokio::time::timeout(Duration::from_secs(3), owner.drain())
        .await
        .expect("poison drain");
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(32))]
    #[test]
    fn arbitrary_disconnect_shutdown_and_drain_schedules_keep_native_custody(
        events in proptest::collection::vec(0u8..5, 1..32)
    ) {
        use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
        let runtime = tokio::runtime::Builder::new_current_thread().enable_time().build().expect("runtime");
        runtime.block_on(async {
            let owner=RuntimeOwner::new();
            let slots=Arc::new(Semaphore::new(2));
            let acknowledged=Arc::new(AtomicBool::new(false));
            let calls=Arc::new(AtomicUsize::new(0));
            let mut jobs=Vec::new();
            let mut admitted=0;
            let mut closed=false;
            for event in events {
                match event {
                    0 => if let Ok(slot)=slots.clone().try_acquire_owned() {
                        let ack=acknowledged.clone();let count=calls.clone();
                        let result=owner.spawn_blocking(Arc::new(slot), move |_| {
                            assert!(!ack.load(Ordering::SeqCst),"native callback after drain acknowledgment");
                            count.fetch_add(1,Ordering::SeqCst);Ok(())
                        });
                        assert_eq!(result.is_err(),closed);
                        if let Ok(job)=result {jobs.push(job);admitted+=1;}
                    },
                    1 => {drop(jobs.pop());},
                    2 => {owner.request_shutdown();closed=true;},
                    3 => {tokio::task::yield_now().await;},
                    _ => {
                        owner.drain().await;closed=true;
                        acknowledged.store(true,Ordering::SeqCst);
                        assert_eq!(slots.available_permits(),2);
                    },
                }
            }
            owner.drain().await;
            acknowledged.store(true,Ordering::SeqCst);
            assert_eq!(slots.available_permits(),2);
            assert!(calls.load(Ordering::SeqCst)<=admitted);
            for job in jobs { let _ = job.await.expect("native worker did not panic"); }
        });
    }
}
