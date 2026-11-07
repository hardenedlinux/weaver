// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Authenticated hard-fact RPC projection through the existing source lanes.
use crate::{grpc::Gateway, grpc_contracts::status, pb, source_owner::SourceOwner};
use tonic::{Response, Status};
use weaver_contracts::SourceIdentity;

impl Gateway {
    fn fact_barrier(barrier: weaver_contracts::FactBarrier) -> pb::HardFactBarrier {
        pb::HardFactBarrier {
            operation_id: barrier.operation_id,
            source_epoch: barrier.source_epoch,
            revision: barrier.revision,
            snapshot: barrier.snapshot,
            floor: barrier.floor,
            pending_prefix: barrier.pending_prefix,
        }
    }

    pub(crate) async fn stage_fact_request(
        &self,
        source: &SourceOwner,
        caller: SourceIdentity,
        change: pb::HardFactIntent,
    ) -> Result<Response<pb::HardFactBarrier>, Status> {
        let intent = weaver_contracts::FactIntent {
            operation_id: change.operation_id,
            domain: change.domain,
            source_epoch: change.source_epoch,
            revision: change.revision,
            previous_snapshot: change.previous_snapshot,
            expected_floor: change.expected_floor,
            available: change.available.ok_or(Status::invalid_argument(
                "explicit hard fact value required",
            ))?,
        };
        intent
            .snapshot()
            .map_err(|_| Status::invalid_argument("invalid hard fact intent"))?;
        let barrier = source.stage_fact(caller, intent).await?;
        Ok(Response::new(Self::fact_barrier(barrier)))
    }

    pub(crate) async fn resolve_fact_request(
        &self,
        source: &SourceOwner,
        caller: SourceIdentity,
        key: pb::HardFactBarrier,
    ) -> Result<Response<pb::FactBarrierResolution>, Status> {
        weaver_contracts::identifier(&key.operation_id)
            .map_err(|_| Status::invalid_argument("invalid hard fact identity"))?;
        if key.snapshot.len() != 64 || key.pending_prefix.len() != 64 {
            return Err(Status::invalid_argument("invalid hard fact barrier"));
        }
        let barrier = weaver_contracts::FactBarrier {
            operation_id: key.operation_id,
            source_epoch: key.source_epoch,
            revision: key.revision,
            snapshot: key.snapshot,
            floor: key.floor,
            pending_prefix: key.pending_prefix,
        };
        let result = match source.prepare_fact(caller.clone(), barrier).await? {
            weaver_ledger::FactPreparation::Resolved(resolution) => resolution,
            weaver_ledger::FactPreparation::Pending(work) => {
                let _slot = self.admission.observation()?;
                let affected = self
                    .runtime
                    .governor()
                    .map_err(status)?
                    .fact_impact(&work)
                    .await
                    .map_err(|error| match error {
                        weaver_governance::SourceJobError::Busy => {
                            Status::resource_exhausted("hard fact derivation lane full")
                        }
                        weaver_governance::SourceJobError::Source(_) => {
                            Status::failed_precondition("hard fact derivation rejected")
                        }
                        _ => Status::unavailable("hard fact derivation interrupted"),
                    })?;
                source.resolve_fact(caller, work, affected).await?
            }
        };
        Ok(Response::new(pb::FactBarrierResolution {
            barrier: Some(Self::fact_barrier(result.barrier)),
            affected: result.affected,
            floor: result.floor,
            previous_pending_prefix: result.previous_pending_prefix,
            remaining_pending_prefix: result.remaining_pending_prefix,
        }))
    }
}
