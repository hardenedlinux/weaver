//! Source-global immutable task identity; neither worker epoch nor family allocates it anew.
use crate::{
    persistence::{self, WriteScope},
    store::db,
};
use weaver_contracts::{
    DomainBinding, Error, Result, Task, TaskAdmission, TaskAdmissionReceipt, body_digest,
};

fn digests(task: &Task, binding: &DomainBinding) -> Result<(String, String)> {
    task.validate()?;
    binding.validate()?;
    Ok((
        body_digest(&serde_json::to_string(task)?),
        body_digest(&serde_json::to_string(binding)?),
    ))
}
fn retain(
    tx: &WriteScope<'_>,
    key: &str,
    task: &Task,
    binding: &DomainBinding,
    publication: Option<&weaver_contracts::PublicationKey>,
) -> Result<()> {
    weaver_contracts::identifier(key)?;
    let (task_digest, binding_digest) = digests(task, binding)?;
    let old = persistence::maybe(
        tx,
        "SELECT family,origin,task_digest,binding_digest FROM original_tasks WHERE task_key=?1",
        [key],
        |r| {
            Ok((
                r.get::<String>(0)?,
                r.get::<String>(1)?,
                r.get::<String>(2)?,
                r.get::<String>(3)?,
            ))
        },
    )
    .map_err(db)?;
    if let Some(old) = old {
        if old
            != (
                task.family.clone(),
                binding.origin.clone(),
                task_digest,
                binding_digest,
            )
        {
            return Err(Error::Conflict(
                "original task identity cannot acquire another family or origin",
            ));
        }
        return require(tx, &task.family);
    }
    let retained:bool=persistence::one(tx,"SELECT EXISTS(SELECT 1 FROM tasks WHERE family=?1) OR EXISTS(SELECT 1 FROM execution_origins WHERE id=?2 OR canonical_family=?1) OR EXISTS(SELECT 1 FROM original_tasks WHERE family=?1 OR origin=?2)",[task.family.as_str(),binding.origin.as_str()],|r|r.get(0)).map_err(db)?;
    if retained {
        return Err(Error::Conflict(
            "original registration missing or identity already allocated",
        ));
    }
    persistence::exec(
        tx,
        "INSERT INTO original_tasks VALUES(?1,?2,?3,?4,?5,?6)",
        [
            key,
            task.family.as_str(),
            binding.origin.as_str(),
            task_digest.as_str(),
            binding_digest.as_str(),
            serde_json::to_string(&publication)?.as_str(),
        ],
    )
    .map_err(db)?;
    Ok(())
}
pub(crate) fn default_binding(
    tx: &WriteScope<'_>,
    task: &Task,
    requested: Option<&DomainBinding>,
    publication: Option<&weaver_contracts::PublicationKey>,
) -> Result<()> {
    // Existing source task APIs use their immutable source family as the original
    // task key. Protocol adapters must never invent source task identities.
    let previous=persistence::maybe(tx,"SELECT o.binding,r.task_key FROM execution_origins o JOIN original_tasks r ON r.origin=o.id AND r.family=o.canonical_family WHERE o.canonical_family=?1",[task.family.as_str()],|r|Ok((r.get::<String>(0)?,r.get::<String>(1)?))).map_err(db)?;
    let (binding, key) = if let Some((body, key)) = previous {
        (weaver_contracts::decode(body.as_bytes())?, key)
    } else {
        (
            DomainBinding {
                origin: task.family.clone(),
                budget: task.family.clone(),
                history: task.family.clone(),
                budget_limit: task.budget,
            },
            task.family.clone(),
        )
    };
    retain(tx, &key, task, requested.unwrap_or(&binding), publication)
}
pub(crate) fn require(tx: &WriteScope<'_>, family: &str) -> Result<()> {
    let row=persistence::maybe(tx,"SELECT r.task_digest,r.binding_digest,t.record,o.binding,r.publication FROM original_tasks r JOIN tasks t ON t.family=r.family JOIN execution_origins o ON o.id=r.origin AND o.canonical_family=r.family WHERE r.family=?1",[family],|r|Ok((r.get::<String>(0)?,r.get::<String>(1)?,r.get::<String>(2)?,r.get::<String>(3)?,r.get::<String>(4)?))).map_err(db)?;
    let (expected_task, expected_binding, task, binding, publication) = row.ok_or(
        Error::Conflict("authoritative original task registration missing"),
    )?;
    let task: Task = weaver_contracts::decode(task.as_bytes())?;
    let binding: DomainBinding = weaver_contracts::decode(binding.as_bytes())?;
    if digests(&task, &binding)? != (expected_task, expected_binding) {
        return Err(Error::Conflict(
            "original task or domain commitment changed",
        ));
    }
    if publication != serde_json::to_string(&crate::task_publication::binding(tx, family)?)? {
        return Err(Error::Conflict(
            "original publication linkage missing or changed",
        ));
    }
    Ok(())
}
pub(crate) fn seal_publication(tx: &WriteScope<'_>, family: &str) -> Result<()> {
    let actual = serde_json::to_string(&crate::task_publication::binding(tx, family)?)?;
    let original: String = persistence::one(
        tx,
        "SELECT publication FROM original_tasks WHERE family=?1",
        [family],
        |r| r.get(0),
    )
    .map_err(db)?;
    if original != actual && original != "null" {
        return Err(Error::Conflict("original publication cannot be replaced"));
    }
    if original != actual {
        persistence::exec(
            tx,
            "UPDATE original_tasks SET publication=?1 WHERE family=?2 AND publication='null'",
            [actual.as_str(), family],
        )
        .map_err(db)?;
    }
    Ok(())
}
impl crate::Ledger {
    /// Atomically register the source task, origin, immutable scope and original decision.
    pub fn register_original_task(
        &mut self,
        task: &Task,
        binding: &DomainBinding,
        admission: &TaskAdmission,
        publication: Option<&weaver_contracts::PublicationKey>,
    ) -> Result<TaskAdmissionReceipt> {
        weaver_contracts::identifier(&admission.task_key)?;
        weaver_contracts::identifier(&admission.operation_id)?;
        let digest = body_digest(&serde_json::to_string(&(
            admission,
            task,
            binding,
            publication,
        ))?);
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        let epoch = crate::source_authority::current(&tx)?.map_or(0, |a| a.epoch);
        if let Some((old, body)) = persistence::maybe(
            &tx,
            "SELECT digest,receipt FROM task_admissions WHERE operation_id=?1",
            [admission.operation_id.as_str()],
            |r| Ok((r.get::<String>(0)?, r.get::<String>(1)?)),
        )
        .map_err(db)?
        {
            let receipt: TaskAdmissionReceipt = weaver_contracts::decode(body.as_bytes())?;
            if old != digest
                || receipt.digest != digest
                || receipt.operation_id != admission.operation_id
                || receipt.task_key != admission.task_key
                || receipt.origin != binding.origin
                || receipt.family != task.family
                || receipt.source_epoch != admission.expected_source_epoch
            {
                return Err(Error::Conflict("original admission decision changed"));
            }
            require(&tx, &task.family)?;
            let registered: String = persistence::one(
                &tx,
                "SELECT task_key FROM original_tasks WHERE family=?1",
                [task.family.as_str()],
                |r| r.get(0),
            )
            .map_err(db)?;
            if registered != admission.task_key {
                return Err(Error::Conflict(
                    "original task key no longer matches its decision",
                ));
            }
            return Ok(receipt);
        }
        if epoch != admission.expected_source_epoch {
            return Err(Error::Conflict("stale source task admission epoch"));
        }
        retain(&tx, &admission.task_key, task, binding, publication)?;
        crate::store::register_task_in(&tx, task, publication, Some(binding))?;
        let receipt = TaskAdmissionReceipt {
            operation_id: admission.operation_id.clone(),
            digest,
            task_key: admission.task_key.clone(),
            family: task.family.clone(),
            origin: binding.origin.clone(),
            source_epoch: epoch,
        };
        persistence::exec(
            &tx,
            "INSERT INTO task_admissions VALUES(?1,?2,?3)",
            [
                receipt.operation_id.as_str(),
                receipt.digest.as_str(),
                serde_json::to_string(&receipt)?.as_str(),
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(receipt)
    }
}
