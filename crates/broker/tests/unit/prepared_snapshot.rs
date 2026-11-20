// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::queue_snapshot;
use crate::ProviderOutput;
use crate::provider::runtime::dispatch_tests::fixtures;
use weaver_contracts::{Error, ProviderEvent, ProviderEventKind, ProviderRoute, Result};
use weaver_ledger::{Ledger, ProviderDelivery, ProviderDispatch};
const SCHEMA: &str = include_str!("../../../../prod/policies/provider/schema.json");
#[derive(Default)]
struct Probe {
    prepared: usize,
    fail: Option<usize>,
    cancel_after_prepare: bool,
    emitted: Vec<(u64, usize)>,
    checkpoint: Option<(
        tokio::sync::oneshot::Sender<()>,
        tokio::sync::oneshot::Receiver<()>,
    )>,
}
impl ProviderOutput for Probe {
    type Slot = ();
    type PreparedFrame = u64;
    fn stopped(&self) -> bool {
        self.cancel_after_prepare && self.prepared == 4
    }
    fn reserve(&mut self) -> Result<()> {
        Ok(())
    }
    fn prepare(
        &mut self,
        _: &ProviderRoute,
        _: &str,
        events: &[ProviderEvent],
        _: &str,
    ) -> Result<u64> {
        self.prepared += 1;
        if self.fail == Some(self.prepared) {
            return Err(Error::Invalid("injected preparation failure"));
        }
        if self.prepared == 4
            && let Some((ready, done)) = self.checkpoint.take()
        {
            ready.send(()).expect("native snapshot fixture");
            done.blocking_recv().expect("native snapshot fixture");
        }
        Ok(events[0].sequence)
    }
    fn emit(&mut self, _: (), frame: u64, _: ProviderDelivery) -> Result<()> {
        self.emitted.push((frame, self.prepared));
        Ok(())
    }
    fn finish_delivery(&mut self, _: &mut Ledger, _: &ProviderDispatch, _: &str) -> Result<()> {
        Ok(())
    }
}
fn fixture(path: &std::path::Path) -> (Ledger, ProviderDispatch) {
    let mut ledger = Ledger::open(path).expect("native snapshot fixture");
    ledger
        .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
        .expect("native snapshot fixture");
    let (task, plan) = fixtures::task_plan(16, "https://provider.invalid/v1/chat/completions");
    ledger
        .register_task(&task)
        .expect("native snapshot fixture");
    ledger
        .enqueue_provider(&plan)
        .expect("native snapshot fixture");
    let permit = ledger
        .consume_provider("f", "infer", &["primary".into()].into())
        .expect("native snapshot fixture");
    ledger
        .dispatch_provider(&permit, || Ok(()))
        .expect("native snapshot fixture");
    (ledger, permit)
}
fn run(ledger: &mut Ledger, permit: &ProviderDispatch, probe: &mut Probe) -> Result<()> {
    let mut ranges: Vec<_> = (0..4)
        .map(|i| {
            vec![ProviderEvent {
                sequence: 0,
                kind: ProviderEventKind::Delta,
                text: format!("row-{i}"),
                tokens: 0,
            }]
        })
        .collect();
    let digests: Vec<_> = ranges
        .iter()
        .map(|rows| {
            weaver_contracts::body_digest(
                &serde_json::to_string(rows).expect("native snapshot fixture"),
            )
        })
        .collect();
    let specs: Vec<_> = digests.iter().map(|digest| (digest.as_str(), 1)).collect();
    probe.reserve()?;
    let releases = ledger.prepare_provider_releases(permit, &specs, "protobuf")?;
    queue_snapshot(ledger, permit, probe, "protobuf", &mut ranges, releases, ())
}
#[test]
fn every_snapshot_frame_is_prepared_before_the_first_guarded_handoff() {
    let dir = tempfile::tempdir().expect("native snapshot fixture");
    let (mut ledger, permit) = fixture(&dir.path().join("ledger.db"));
    let mut probe = Probe::default();
    run(&mut ledger, &permit, &mut probe).expect("native snapshot fixture");
    assert_eq!(probe.emitted, vec![(0, 4), (1, 4), (2, 4), (3, 4)]);
}
#[test]
fn four_fixed_preparation_failures_publish_no_part_of_that_snapshot() {
    for failure in 1..=4 {
        let dir = tempfile::tempdir().expect("native snapshot fixture");
        let (mut ledger, permit) = fixture(&dir.path().join("ledger.db"));
        let mut probe = Probe {
            fail: Some(failure),
            ..Default::default()
        };
        assert!(run(&mut ledger, &permit, &mut probe).is_err());
        assert_eq!(probe.prepared, failure);
        assert!(
            probe.emitted.is_empty(),
            "prefix escaped at failure {failure}"
        );
        assert_eq!(
            ledger
                .provider_receipt("f", "infer")
                .expect("native snapshot fixture")
                .expect("native snapshot fixture")
                .held,
            permit.plan().ceiling
        );
    }
}
#[test]
fn cancellation_after_preparation_blocks_the_final_callback() {
    let dir = tempfile::tempdir().expect("native snapshot fixture");
    let (mut ledger, permit) = fixture(&dir.path().join("ledger.db"));
    let mut probe = Probe {
        cancel_after_prepare: true,
        ..Default::default()
    };
    assert!(run(&mut ledger, &permit, &mut probe).is_err());
    assert_eq!(probe.prepared, 4);
    assert!(probe.emitted.is_empty());
    assert_eq!(
        ledger
            .provider_receipt("f", "infer")
            .expect("native snapshot fixture")
            .expect("native snapshot fixture")
            .held,
        permit.plan().ceiling
    );
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_real_policy_writer_after_encoding_prevents_every_handoff() {
    let dir = tempfile::tempdir().expect("native snapshot fixture");
    let path = dir.path().join("ledger.db");
    let worker_path = path.clone();
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    let (done_tx, done_rx) = tokio::sync::oneshot::channel();
    let owner = tokio::task::spawn_blocking(move || {
        let (mut ledger, permit) = fixture(&worker_path);
        let mut probe = Probe {
            checkpoint: Some((ready_tx, done_rx)),
            ..Default::default()
        };
        let result = run(&mut ledger, &permit, &mut probe);
        let held = ledger
            .provider_receipt("f", "infer")
            .expect("native snapshot fixture")
            .expect("native snapshot fixture")
            .held;
        (result, probe.emitted, held, permit.plan().ceiling)
    });
    ready_rx.await.expect("native snapshot fixture");
    tokio::task::spawn_blocking(move || {
        let mut writer = Ledger::open(path).expect("native snapshot fixture");
        writer
            .publish(Some(0), "forbid(principal,action,resource);", 2)
            .expect("native snapshot fixture");
        done_tx.send(()).expect("native snapshot fixture");
    })
    .await
    .expect("native snapshot fixture");
    let (result, emitted, held, ceiling) = owner.await.expect("native snapshot fixture");
    assert!(result.is_err());
    assert!(emitted.is_empty());
    assert_eq!(held, ceiling);
}
