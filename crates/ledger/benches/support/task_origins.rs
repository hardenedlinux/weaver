use criterion::{BatchSize, Criterion};
use weaver_contracts::{DomainBinding, SourceIdentity, Task, TaskAdmission};
use weaver_ledger::{
    Ledger,
    persistence::{Journal, Session},
};
struct Fixture {
    directory: tempfile::TempDir,
    storage: Session,
    ledger: Ledger,
    task: Task,
    binding: DomainBinding,
    admission: TaskAdmission,
    source: SourceIdentity,
}
fn fresh(prepared: bool) -> Fixture {
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("origin.db");
    let storage = Session::open_with_journal(&path, Journal::Mvcc).expect("owner");
    let mut ledger = Ledger::open(&path).expect("ledger");
    let source = super::source_fixture::source_identity(0);
    ledger
        .with_authenticated_source(&source, |_| Ok(()))
        .expect("source enrollment");
    let (task, _) = super::fixtures::task_plan(128, "https://provider.invalid/v1/chat/completions");
    let binding = DomainBinding {
        origin: "source-origin".into(),
        budget: "shared".into(),
        history: "shared".into(),
        budget_limit: task.budget,
    };
    let admission = TaskAdmission {
        task_key: "original-source-task".into(),
        operation_id: "source-task-commit".into(),
        expected_source_epoch: 0,
    };
    if prepared {
        ledger
            .with_authenticated_source(&source, |l| {
                l.register_original_task(&task, &binding, &admission, None)
            })
            .expect("precommitted original");
    }
    Fixture {
        directory,
        storage,
        ledger,
        task,
        binding,
        admission,
        source,
    }
}
/// Time the source identity join, deciding registration and natural resource drain.
pub fn benchmarks(c: &mut Criterion) {
    let mut group = c.benchmark_group("ledger/task_origin_registration");
    for (name, prepared, conflict) in [
        ("fresh", false, false),
        ("receipt-replay", true, false),
        ("rebind-rejected", true, true),
    ] {
        group.bench_function(name, |b| {
            b.iter_batched(
                || fresh(prepared),
                |mut f| {
                    if conflict {
                        f.admission.operation_id = "new-attempt".into();
                        f.binding.origin = "replacement-origin".into();
                    }
                    let result = f.ledger.with_authenticated_source(&f.source, |l| {
                        l.register_original_task(&f.task, &f.binding, &f.admission, None)
                    });
                    assert_eq!(result.is_ok(), !conflict);
                    f.ledger.close().expect("ledger drain");
                    f.storage.close().expect("storage drain");
                    drop(f.directory);
                },
                BatchSize::PerIteration,
            )
        });
    }
}
