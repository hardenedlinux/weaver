//! Provision outside timing; measure two original-family admissions plus worker drain.
use std::{collections::BTreeSet, time::Duration};
use weaver_contracts::ProviderPlan;
use weaver_ledger::{
    Ledger,
    persistence::{Journal, Session},
};

pub struct Fixture {
    directory: tempfile::TempDir,
    storage: Session,
    first: Ledger,
    second: Ledger,
    left: ProviderPlan,
    right: ProviderPlan,
}
pub fn fresh(journal: Journal) -> Fixture {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("pair.db");
    let storage = Session::open_with_journal(&path, journal).expect("selected profile");
    let mut first = Ledger::open(&path).expect("first connection");
    let policy = super::policy_fixture::POLICY.replace(
        "context.family == \"f\"",
        "[\"left\", \"right\"].contains(context.family)",
    );
    first
        .publish_typed(None, &policy, super::policy_fixture::SCHEMA, 1)
        .expect("authority");
    let make = |family: &str, ledger: &mut Ledger| {
        let (mut task, mut plan) =
            super::fixtures::task_plan(128, "https://provider.invalid/v1/chat/completions");
        task.family = family.into();
        plan.family = family.into();
        task.stream_contracts
            .insert("infer".into(), plan.digest().expect("original commitment"));
        ledger.register_task(&task).expect("independent original");
        plan
    };
    let left = make("left", &mut first);
    let right = make("right", &mut first);
    let second = Ledger::open(&path).expect("second connection");
    Fixture {
        directory,
        storage,
        first,
        second,
        left,
        right,
    }
}
impl Fixture {
    pub fn prepare(mut self) -> Ready {
        self.first
            .enqueue_provider(&self.left)
            .expect("left reserve");
        self.second
            .enqueue_provider(&self.right)
            .expect("right reserve");
        let eligible = BTreeSet::from(["primary".into()]);
        let left = self
            .first
            .consume_provider("left", "infer", &eligible)
            .expect("left burn");
        let right = self
            .second
            .consume_provider("right", "infer", &eligible)
            .expect("right burn");
        Ready {
            fixture: self,
            left,
            right,
        }
    }
    pub fn reserve(self) {
        let Self {
            directory,
            storage,
            mut first,
            mut second,
            left,
            right,
        } = self;
        std::thread::scope(|scope| {
            let job = scope.spawn(|| second.enqueue_provider(&right).expect("right admission"));
            first.enqueue_provider(&left).expect("left admission");
            job.join().expect("natural worker drain");
        });
        assert_eq!(first.held("left").expect("left exposure"), 4);
        assert_eq!(first.held("right").expect("right exposure"), 4);
        first.close().expect("first drain");
        second.close().expect("second drain");
        storage.close().expect("owner drain");
        drop(directory);
    }
}

pub struct Ready {
    fixture: Fixture,
    left: weaver_ledger::ProviderDispatch,
    right: weaver_ledger::ProviderDispatch,
}
impl Ready {
    pub fn send(self, serialized: bool) {
        let Self {
            fixture,
            left,
            right,
        } = self;
        let Fixture {
            directory,
            storage,
            mut first,
            mut second,
            ..
        } = fixture;
        let serial = std::sync::Mutex::new(());
        std::thread::scope(|scope| {
            let job = scope.spawn(|| {
                let _control = if serialized {
                    Some(serial.lock().expect("serial control"))
                } else {
                    None
                };
                first
                    .dispatch_provider(&left, || std::thread::sleep(Duration::from_millis(2)))
                    .expect("left bounded effect")
            });
            let _control = if serialized {
                Some(serial.lock().expect("serial control"))
            } else {
                None
            };
            second
                .dispatch_provider(&right, || std::thread::sleep(Duration::from_millis(2)))
                .expect("right bounded effect");
            drop(_control);
            job.join().expect("natural drain");
        });
        assert_eq!(first.held("left").expect("left hold"), 4);
        assert_eq!(second.held("right").expect("right hold"), 4);
        first.close().expect("first close");
        second.close().expect("second close");
        storage.close().expect("owner close");
        drop(directory);
    }
}
