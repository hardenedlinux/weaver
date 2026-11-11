// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{
    OwnedSource, SourceClient, SourceError, SourceInbox, SourceJobError, source_fixture as fixture,
    source_lane,
};
use proptest::{
    prop_assert, prop_assert_eq, proptest,
    test_runner::{Config, RngSeed},
};
use std::{
    future::Future,
    num::NonZeroUsize,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    task::{Context, Poll, Wake, Waker},
    thread,
    time::Duration,
};
fn original() -> OwnedSource {
    OwnedSource::from_source(fixture::source()).expect("source")
}
fn copied(source: &OwnedSource) -> Result<OwnedSource, SourceError> {
    OwnedSource::from_source(source.data().clone())
}
struct Owner {
    client: SourceClient,
    thread: Option<thread::JoinHandle<()>>,
}
impl Owner {
    fn start(capacity: usize, run: impl FnOnce(SourceInbox) + Send + 'static) -> Self {
        let (client, inbox) = source_lane(NonZeroUsize::new(capacity).expect("capacity"));
        Self {
            client,
            thread: Some(thread::spawn(move || run(inbox))),
        }
    }
    fn finish(mut self) -> thread::Result<()> {
        self.client.close();
        self.thread.take().expect("owner").join()
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        self.client.close();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
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
struct Signal(mpsc::Sender<()>);
impl Wake for Signal {
    fn wake(self: Arc<Self>) {
        let _ = self.0.send(());
    }
}
fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime")
}
#[test]
fn ready_results_keep_capacity_until_observed_and_close_fences_delivery() {
    // Park the owner until the receiver has registered its ready wake.
    let (release, wait) = mpsc::channel();
    let owner = Owner::start(1, move |inbox| {
        wait.recv().expect("release");
        inbox.run(copied);
    });
    let release = Release(Some(release));
    let mut job = owner.client.submit(original()).expect("admitted");
    let (wake, ready) = mpsc::channel();
    let waker = Waker::from(Arc::new(Signal(wake)));
    assert!(matches!(
        Pin::new(&mut job).poll(&mut Context::from_waker(&waker)),
        Poll::Pending
    ));
    drop(release);
    ready.recv_timeout(Duration::from_secs(5)).expect("ready");
    assert!(matches!(
        owner.client.submit(original()),
        Err(SourceJobError::Busy)
    ));
    owner.client.close();
    assert!(matches!(
        runtime().block_on(job),
        Err(SourceJobError::Closed)
    ));
    owner.finish().expect("drained");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn governor_observation_waits_for_capacity_or_shutdown() {
    for close_owner in [false, true] {
        let owner = Owner::start(1, |inbox| {
            inbox.run_with_governor(
                (),
                |_, source| copied(source),
                |_, cut| Ok(cut.pending.clone()),
            );
        });
        let job = owner
            .client
            .submit(original())
            .expect("occupy the only slot");
        let observation = owner.client.derive(crate::GovernorCut {
            topology: Arc::new(crate::GovernorTopology {
                nodes: vec!["next".into()],
                edges: vec![],
                choice_arms: vec![],
                choice_join: vec![],
                nested_selectors: vec![],
            }),
            complete: vec![],
            available: vec!["next".into()],
            pending: vec!["next".into()],
            choice_result: vec![],
            choice_decided: vec![],
            nested_results: vec![],
            nested_decisions: vec![],
        });
        tokio::pin!(observation);
        assert!(matches!(
            observation
                .as_mut()
                .poll(&mut Context::from_waker(Waker::noop())),
            Poll::Pending
        ));
        if close_owner {
            owner.client.close();
        } else {
            job.await.expect("release the source slot");
        }
        let result = tokio::time::timeout(Duration::from_secs(3), observation)
            .await
            .expect("waiting Governor resumes");
        if close_owner {
            assert_eq!(result, Err(SourceJobError::Closed));
        } else {
            assert_eq!(
                result.expect("derived"),
                crate::DerivationOutput::Nodes(vec!["next".into()])
            );
        }
    }
}

#[test]
fn cancelled_running_work_keeps_its_slot_until_natural_return() {
    let (entered, started) = mpsc::channel();
    let (release, wait) = mpsc::channel();
    let owner = Owner::start(1, move |inbox| {
        inbox.run(move |source| {
            entered.send(()).expect("start");
            wait.recv().expect("release");
            copied(source)
        })
    });
    let release = Release(Some(release));
    let mut job = owner.client.submit(original()).expect("source");
    started
        .recv_timeout(Duration::from_secs(5))
        .expect("running");
    job.cancel();
    assert!(matches!(
        runtime().block_on(job),
        Err(SourceJobError::Cancelled)
    ));
    assert!(matches!(
        owner.client.submit(original()),
        Err(SourceJobError::Busy)
    ));
    drop(release);
    owner.finish().expect("natural finish");
}
#[test]
fn active_compiler_observes_both_request_and_owner_cancellation() {
    for close_owner in [false, true] {
        let (entered, started) = mpsc::channel();
        let (release, wait) = mpsc::channel();
        let owner = Owner::start(1, move |inbox| {
            inbox.run_with_cancellable_governor(
                (),
                |_, source, cancel| {
                    entered.send(cancel.clone()).expect("active compiler token");
                    wait.recv().expect("release compiler");
                    copied(source)
                },
                |_, _| Err(SourceError::Contract),
            )
        });
        let release = Release(Some(release));
        let mut job = owner.client.submit(original()).expect("admitted");
        let cancel = started
            .recv_timeout(Duration::from_secs(5))
            .expect("running");
        assert!(!cancel.is_cancelled());
        if close_owner {
            owner.client.close();
        } else {
            job.cancel();
        }
        assert!(cancel.is_cancelled());
        let expected = if close_owner {
            SourceJobError::Closed
        } else {
            SourceJobError::Cancelled
        };
        assert!(matches!(runtime().block_on(job), Err(error) if error == expected));
        drop(release);
        owner.finish().expect("natural finish");
    }
}
#[test]
fn cancelled_queued_work_does_not_enter_the_compiler() {
    let (entered, started) = mpsc::channel();
    let (release, wait) = mpsc::channel();
    let calls = Arc::new(AtomicUsize::new(0));
    let seen = calls.clone();
    let owner = Owner::start(2, move |inbox| {
        inbox.run(move |source| {
            seen.fetch_add(1, Ordering::SeqCst);
            entered.send(()).expect("start");
            wait.recv().expect("release");
            copied(source)
        })
    });
    let release = Release(Some(release));
    let first = owner.client.submit(original()).expect("first");
    started
        .recv_timeout(Duration::from_secs(5))
        .expect("running");
    let second = owner.client.submit(original()).expect("queued");
    drop(second);
    assert!(matches!(
        owner.client.submit(original()),
        Err(SourceJobError::Busy)
    ));
    drop(release);
    assert!(runtime().block_on(first).is_ok());
    owner.finish().expect("finish");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}
#[test]
fn ready_cancellation_discards_data_and_releases_its_slot() {
    let (release, wait) = mpsc::channel();
    let owner = Owner::start(1, move |inbox| {
        wait.recv().expect("release");
        inbox.run(copied);
    });
    let release = Release(Some(release));
    let mut job = owner.client.submit(original()).expect("source");
    let (wake, ready) = mpsc::channel();
    let waker = Waker::from(Arc::new(Signal(wake)));
    assert!(matches!(
        Pin::new(&mut job).poll(&mut Context::from_waker(&waker)),
        Poll::Pending
    ));
    drop(release);
    ready.recv_timeout(Duration::from_secs(5)).expect("ready");
    job.cancel();
    assert!(matches!(
        owner.client.submit(original()),
        Err(SourceJobError::Busy)
    ));
    assert!(matches!(
        runtime().block_on(job),
        Err(SourceJobError::Cancelled)
    ));
    assert!(
        runtime()
            .block_on(owner.client.submit(original()).expect("slot released"))
            .is_ok()
    );
    owner.finish().expect("finish");
}
#[test]
fn compiler_can_be_non_send_and_changed_content_is_not_delivered() {
    let owner = Owner::start(2, |inbox| {
        let calls = std::rc::Rc::new(std::cell::Cell::new(0));
        let thread = thread::current().id();
        inbox.run(move |source| {
            assert_eq!(thread::current().id(), thread);
            calls.set(calls.get() + 1);
            let mut data = source.data().clone();
            if calls.get() == 1 {
                data.tasks[0].budget += 1;
            }
            OwnedSource::from_source(data)
        });
    });
    assert!(matches!(
        runtime().block_on(owner.client.submit(original()).expect("first")),
        Err(SourceJobError::Source(SourceError::Binding))
    ));
    assert!(
        runtime()
            .block_on(owner.client.submit(original()).expect("second"))
            .is_ok()
    );
    owner.finish().expect("finish");
}
#[test]
fn receiver_drop_and_compiler_panic_close_the_lane() {
    let (client, inbox) = source_lane(NonZeroUsize::new(2).expect("capacity"));
    let job = client.submit(original()).expect("job");
    drop(inbox);
    assert!(matches!(
        runtime().block_on(job),
        Err(SourceJobError::Closed)
    ));
    assert!(matches!(
        client.submit(original()),
        Err(SourceJobError::Closed)
    ));
    let owner = Owner::start(2, |inbox| {
        inbox.run(|_| panic!("test compiler panic outside gates"))
    });
    let job = owner.client.submit(original()).expect("job");
    assert!(matches!(
        runtime().block_on(job),
        Err(SourceJobError::Closed | SourceJobError::Unavailable)
    ));
    assert!(owner.finish().is_err());
}
#[test]
fn scheme_failure_closes_owner_without_retry_or_recreation() {
    let calls = Arc::new(AtomicUsize::new(0));
    let seen = calls.clone();
    let owner = Owner::start(2, move |inbox| {
        inbox.run(|_| {
            seen.fetch_add(1, Ordering::SeqCst);
            Err(SourceError::Scheme)
        })
    });
    assert!(matches!(
        runtime().block_on(owner.client.submit(original()).expect("job")),
        Err(SourceJobError::Closed | SourceJobError::Unavailable)
    ));
    assert!(matches!(
        owner.client.submit(original()),
        Err(SourceJobError::Closed)
    ));
    owner.finish().expect("natural owner termination");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}
proptest! {
    #![proptest_config(Config {cases:128,rng_seed:RngSeed::Fixed(293),..Config::default()})]
    #[test]
    fn queued_cancellation_and_terminal_close_preserve_originals(mask in 0u8..8,close in proptest::bool::ANY) {
        let (client,inbox)=source_lane(NonZeroUsize::new(3).expect("capacity"));
        let mut jobs=Vec::new();for index in 0..3 {
            let mut job=client.submit(original()).expect("bounded source");
            if mask & (1<<index)!=0 {job.cancel();}jobs.push(job);
        }
        if close {client.close();}
        let calls=Arc::new(AtomicUsize::new(0));let seen=calls.clone();
        let worker=thread::spawn(move||inbox.run(move|source|{seen.fetch_add(1,Ordering::SeqCst);copied(source)}));
        let rt=runtime();let mut valid=true;
        for (index,job) in jobs.into_iter().enumerate() {
            let result=rt.block_on(job);
            valid &= if close {matches!(result,Err(SourceJobError::Closed))}
                else if mask&(1<<index)!=0 {matches!(result,Err(SourceJobError::Cancelled))}
                else {result.is_ok_and(|value|value.source().task().family=="f")};
        }
        client.close();worker.join().expect("drained");
        prop_assert!(valid);
        prop_assert_eq!(calls.load(Ordering::SeqCst),if close {0} else {3-mask.count_ones() as usize});
    }
}
