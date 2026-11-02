//! Provision outside timing; measure two original-family admissions plus worker drain.
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
