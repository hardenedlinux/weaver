// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! The cluster supplies observations. The source owner retains the authoritative cut.
use crate::{grpc_config::read_path, pb, source_prepare};
use futures_util::StreamExt;
use kube::{
    Api,
    api::{ApiResource, DynamicObject, GroupVersionKind, Patch, PatchParams},
    runtime::{WatchStreamExt, watcher},
};
use serde::Deserialize;
use serde_json::json;
use std::{path::Path, time::Duration};
use weaver_contracts::{Error, Result, body_digest};

const RECONCILE_TIMEOUT: Duration = Duration::from_secs(12);
const RESYNC_INTERVAL: Duration = Duration::from_secs(15);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    source: source_prepare::SourceConnection,
    kubernetes: Binding,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Binding {
    namespace: String,
    name: String,
    uid: String,
    domain: String,
}

impl Binding {
    fn matches(&self, object: &DynamicObject) -> bool {
        object.metadata.namespace.as_deref() == Some(&self.namespace)
            && object.metadata.name.as_deref() == Some(&self.name)
            && object.metadata.uid.as_deref() == Some(&self.uid)
            && object.metadata.deletion_timestamp.is_none()
    }
}

async fn reconcile(
    binding: &Binding,
    api: &Api<DynamicObject>,
    source: &mut source_prepare::Client,
) -> Result<()> {
    // Capture the ledger predecessor before reading the desired state. A competing
    // write after that capture invalidates the exact floor used for any new intent.
    let state = source
        .inspect_hard_fact(pb::Empty {})
        .await
        .map_err(|_| Error::Conflict("hard fact feed observation failed"))?
        .into_inner();
    if state.domain != binding.domain {
        return Err(Error::Conflict("Kubernetes hard fact feed binding"));
    }
    let object = api
        .get_opt(&binding.name)
        .await
        .map_err(|_| Error::Conflict("Kubernetes resource observation failed"))?;
    let matching = object.as_ref().filter(|object| binding.matches(object));
    let (available, generation) = match matching {
        Some(object) => (
            object
                .data
                .pointer("/spec/available")
                .and_then(serde_json::Value::as_bool)
                .ok_or(Error::Invalid("ProviderAvailability spec"))?,
            Some(
                object
                    .metadata
                    .generation
                    .filter(|value| *value > 0)
                    .ok_or(Error::Invalid("ProviderAvailability generation"))?,
            ),
        ),
        None => (false, None),
    };

    let mut pending = state.pending;
    let (effective, prior_revision, previous_snapshot) = match pending.last() {
        Some(tail) => {
            let barrier = tail
                .barrier
                .as_ref()
                .ok_or(Error::Invalid("hard fact tail missing"))?;
            (
                Some(tail.available),
                barrier.revision,
                barrier.snapshot.as_str(),
            )
        }
        None => (state.available, state.revision, state.snapshot.as_str()),
    };

    // Install the currently observed intent before resolving any older pending
    // work. Thus resolving a stale available intent cannot open a withdrawn cut.
    if effective != Some(available) {
        let revision = prior_revision
            .checked_add(1)
            .ok_or(Error::Invalid("hard fact revision"))?;
        let encoded = serde_json::to_string(&(
            "weaver.kubernetes.provider-availability.v1",
            &binding.namespace,
            &binding.name,
            &binding.uid,
            generation,
            &state.domain,
            state.source_epoch,
            revision,
            previous_snapshot,
            state.floor,
            available,
        ))?;
        let intent = weaver_contracts::FactIntent {
            operation_id: body_digest(&encoded),
            domain: state.domain,
            source_epoch: state.source_epoch,
            revision,
            previous_snapshot: previous_snapshot.to_owned(),
            expected_floor: state.floor,
            available,
        };
        let snapshot = intent.snapshot()?;
        let barrier = source
            .stage_hard_fact(pb::HardFactIntent {
                operation_id: intent.operation_id.clone(),
                domain: intent.domain,
                source_epoch: intent.source_epoch,
                revision: intent.revision,
                previous_snapshot: intent.previous_snapshot,
                expected_floor: intent.expected_floor,
                available: Some(intent.available),
            })
            .await
            .map_err(|_| Error::Conflict("Kubernetes hard fact staging result unknown"))?
            .into_inner();
        if barrier.operation_id != intent.operation_id
            || barrier.revision != intent.revision
            || barrier.source_epoch != intent.source_epoch
            || barrier.snapshot != snapshot
            || Some(barrier.floor) != intent.expected_floor.checked_add(1)
        {
            return Err(Error::Conflict(
                "Kubernetes hard fact staging receipt binding",
            ));
        }
        pending.push(pb::PendingHardFact {
            barrier: Some(barrier),
            available,
        });
    }

    let mut cut = (state.revision, state.snapshot);
    for item in pending {
        let barrier = item
            .barrier
            .ok_or(Error::Invalid("hard fact barrier missing"))?;
        let receipt = source
            .resolve_hard_fact(barrier.clone())
            .await
            .map_err(|_| Error::Conflict("Kubernetes hard fact resolution result unknown"))?
            .into_inner();
        if receipt.barrier.as_ref() != Some(&barrier) {
            return Err(Error::Conflict(
                "Kubernetes hard fact resolution receipt binding",
            ));
        }
        cut = (barrier.revision, barrier.snapshot);
    }

    // Observe the ledger after all attempts. A concurrent staging or resolution
    // supersedes the status update even if an earlier exact receipt still exists.
    if cut.0 != state.revision {
        let installed = source
            .inspect_hard_fact(pb::Empty {})
            .await
            .map_err(|_| Error::Conflict("hard fact installation observation failed"))?
            .into_inner();
        if !installed.pending.is_empty()
            || installed.source_epoch != state.source_epoch
            || installed.revision != cut.0
            || installed.snapshot != cut.1
            || installed.available != Some(available)
        {
            return Err(Error::Conflict("Kubernetes hard fact cut superseded"));
        }
    }
    if let (Some(object), Some(generation)) = (matching, generation) {
        let status = json!({
            "observedGeneration": generation,
            "sourceEpoch": state.source_epoch,
            "revision": cut.0,
            "snapshot": cut.1,
        });
        if object.data.get("status") != Some(&status) {
            let resource_version = object
                .metadata
                .resource_version
                .as_deref()
                .ok_or(Error::Invalid("ProviderAvailability resource version"))?;
            let patch = json!({
                "metadata": {"resourceVersion": resource_version},
                "status": status,
            });
            api.patch_status(
                &binding.name,
                &PatchParams::default(),
                &Patch::Merge(&patch),
            )
            .await
            .map_err(|_| Error::Conflict("ProviderAvailability status write rejected"))?;
        }
    }
    Ok(())
}

pub(crate) async fn run(path: &Path) -> Result<()> {
    let bytes = read_path(path)?;
    let text = std::str::from_utf8(&bytes).map_err(|_| Error::Invalid("weaver.toml encoding"))?;
    let mut config = toml::from_str::<Config>(text)
        .map_err(|_| Error::Invalid("weaver.toml Kubernetes configuration"))?;
    let binding = config.kubernetes;
    for identity in [
        &binding.namespace,
        &binding.name,
        &binding.uid,
        &binding.domain,
    ] {
        weaver_contracts::identifier(identity)?;
    }
    if config.source.producer.is_some() || config.source.file.is_some() {
        return Err(Error::Invalid("Kubernetes hard fact source configuration"));
    }
    config.source.resolve_paths(path)?;
    let mut source =
        tokio::time::timeout(RECONCILE_TIMEOUT, source_prepare::connect(&config.source))
            .await
            .map_err(|_| Error::Conflict("source listener connection deadline"))??;
    let cluster = kube::Client::try_default()
        .await
        .map_err(|_| Error::Invalid("Kubernetes client configuration"))?;
    let resource = ApiResource::from_gvk_with_plural(
        &GroupVersionKind::gvk(
            "weaver.hardenedlinux.org",
            "v1alpha1",
            "ProviderAvailability",
        ),
        "provideravailabilities",
    );
    let api = Api::<DynamicObject>::namespaced_with(cluster, &binding.namespace, &resource);
    let events = watcher(
        api.clone(),
        watcher::Config::default().fields(&format!("metadata.name={}", binding.name)),
    )
    .default_backoff();
    tokio::pin!(events);
    let mut resync = tokio::time::interval(RESYNC_INTERVAL);
    resync.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let stop = crate::shutdown::signal()?;
    tokio::pin!(stop);
    loop {
        tokio::select! {
            _ = &mut stop => return Ok(()),
            _ = resync.tick() => {}
            event = events.next() => match event {
                Some(Ok(watcher::Event::Apply(_) | watcher::Event::Delete(_) | watcher::Event::InitDone)) => {}
                Some(Ok(_)) => continue,
                Some(Err(_)) => {
                    eprintln!("weaver Kubernetes watch interrupted; kube-rs will recover");
                    continue;
                }
                None => return Err(Error::Conflict("Kubernetes watch closed")),
            },
        }
        match tokio::time::timeout(RECONCILE_TIMEOUT, reconcile(&binding, &api, &mut source)).await
        {
            Ok(Ok(())) => {}
            Ok(Err(error)) => eprintln!("weaver Kubernetes reconciliation: {error}"),
            Err(_) => eprintln!("weaver Kubernetes reconciliation deadline"),
        }
    }
}
