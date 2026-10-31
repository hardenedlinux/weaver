//! Actual approved SDK graph on the server's existing tracked blocking owner.
use gerbil_scheme::GerbilRuntime;
use std::{cell::Cell, rc::Rc, sync::Arc, thread::ThreadId};
use tokio::sync::{Semaphore, oneshot};
use weaver_governance::{OwnedSource, SourceError, materialize_source, root_source};
use weaver_server::ServiceRuntime;
#[path = "../../../governance/tests/unit/fixture.rs"]
mod fixture;
#[path = "../../../governance/tests/integration/program.rs"]
mod program;

struct Compiler {
    vm: Option<GerbilRuntime>,
    owner: ThreadId,
    local: Rc<Cell<usize>>,
    cleanup: Option<oneshot::Sender<usize>>,
}
impl Compiler {
    fn compile(&self, source: &OwnedSource) -> Result<OwnedSource, SourceError> {
        assert_eq!(std::thread::current().id(), self.owner);
        self.local.set(self.local.get() + 1);
        let vm = self.vm.as_ref().ok_or(SourceError::Scheme)?;
        let input = root_source(vm, source)?;
        let capture = program::capture(vm);
        let output = capture
            .call(&input)
            .into_result()
            .map_err(|_| SourceError::Scheme)?;
        materialize_source(output)
    }
}
impl Drop for Compiler {
    fn drop(&mut self) {
        assert_eq!(std::thread::current().id(), self.owner);
        drop(self.vm.take());
        if let Some(cleanup) = self.cleanup.take() {
            let _ = cleanup.send(self.local.get());
        }
    }
}
#[tokio::test]
async fn actual_scheme_vm_is_owner_local_and_cleanup_precedes_shared_drain() {
    let runtime = ServiceRuntime::new();
    let capacity = std::thread::available_parallelism().expect("host budget");
    let permits = Arc::new(Semaphore::new(capacity.get()));
    let slot = Arc::new(permits.clone().try_acquire_owned().expect("worker budget"));
    let (cleanup, cleaned) = oneshot::channel();
    let worker = runtime
        .start_governance(slot, capacity, move || {
            assert_eq!(weaver_policy_ffi::weaver_policy_abi_v1(), 0x0001_0000);
            let vm = program::initialize();
            eprintln!(
                "server governance VM active_processors={}",
                vm.active_processors().expect("processors")
            );
            let compiler = Compiler {
                vm: Some(vm),
                owner: std::thread::current().id(),
                local: Rc::new(Cell::new(0)),
                cleanup: Some(cleanup),
            };
            Ok(move |source: &OwnedSource| compiler.compile(source))
        })
        .await
        .expect("approved compiler initialized on worker");
    let original = fixture::source();
    let authority = weaver_contracts::SourceAuthority {
        epoch: 1,
        identity: weaver_contracts::SourceIdentity {
            certificate_sha256: "1".repeat(64),
            public_key_sha256: "2".repeat(64),
            credential_sha256: "3".repeat(64),
        },
    };
    let catalog = weaver_governance::ProducerCatalog::from_entries(vec![
        weaver_governance::ApprovedProducer::new(
            "approved-AA".into(),
            authority.clone(),
            OwnedSource::from_source(original.clone()).expect("original"),
        )
        .expect("host binding"),
    ])
    .expect("catalog");
    worker
        .publish_producers(catalog)
        .expect("publish immutable catalog");
    let client = runtime.producers().expect("installed producer set");
    let result = client
        .submit("approved-AA", &authority)
        .expect("bounded admission")
        .await
        .expect("actual AA capture and binding");
    runtime.request_shutdown();
    runtime.drain().await;
    assert_eq!(
        cleaned
            .await
            .expect("natural VM cleanup before acknowledgment"),
        1
    );
    assert_eq!(permits.available_permits(), capacity.get());
    worker.finish().await.expect("tracked worker joined");
    assert!(result.source().data() == &original);
    assert!(matches!(
        client.submit("approved-AA", &authority),
        Err(weaver_governance::CatalogError::Schedule(
            weaver_governance::SourceJobError::Closed
        ))
    ));
}
