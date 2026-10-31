//! Typed source selection and original commitment checks.
use serde::Deserialize;
use std::collections::BTreeSet;
use weaver_contracts::{ProviderPlan, Publication, Task};

/// Maximum UTF-8 source payload copied at a boundary.
pub const MAX_SOURCE_BYTES: usize = 8 * 1024 * 1024;

/// Normalized categories intentionally carry no source text or parser payload.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum SourceError {
    #[error("source size or shape bound")]
    Bound,
    #[error("source shape or native contract")]
    Contract,
    #[error("original source selection or commitment")]
    Binding,
    #[error("Scheme owner or rooted conversion failed")]
    Scheme,
}

#[derive(Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
/// Original governor family and selected node identities.
pub struct SourceSelection {
    pub schema: String,
    pub family: String,
    pub open_nodes: Vec<String>,
}
#[derive(Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
/// Concrete source records; data ownership grants no execution authority.
pub struct SourceData {
    pub governance: SourceSelection,
    pub tasks: Vec<Task>,
    pub plans: Vec<ProviderPlan>,
    pub publication: Publication,
}

/// Rust-owned typed source data, not an encoded transport blob or publisher permit.
/// No VM, callback, raw pointer or borrowed source survives in this type.
pub struct OwnedSource {
    data: SourceData,
}

impl OwnedSource {
    /// Borrow concrete source data; this conveys no publication or execution authority.
    pub fn data(&self) -> &SourceData {
        &self.data
    }
    /// Validate concrete source records without decoding an interop blob.
    pub fn from_source(data: SourceData) -> Result<Self, SourceError> {
        validate(&data)?;
        Ok(Self { data })
    }
    pub fn task(&self) -> &Task {
        &self.data.tasks[0]
    }
    pub fn plans(&self) -> &[ProviderPlan] {
        &self.data.plans
    }
    pub fn publication(&self) -> &Publication {
        &self.data.publication
    }
}

fn validate(wire: &SourceData) -> Result<(), SourceError> {
    if wire.tasks.len() != 1 || wire.plans.is_empty() || wire.plans.len() > 64 {
        return Err(SourceError::Binding);
    }
    let task = &wire.tasks[0];
    task.validate().map_err(|_| SourceError::Contract)?;
    wire.publication
        .validate()
        .map_err(|_| SourceError::Contract)?;
    let selected: BTreeSet<_> = wire.governance.open_nodes.iter().collect();
    let original: BTreeSet<_> = task.nodes.iter().collect();
    if wire.governance.schema != "agentic-ai-lab.loop-governor.v1"
        || wire.governance.family != task.family
        || selected.len() != wire.governance.open_nodes.len()
        || selected != original
        || wire.plans.len() != selected.len()
    {
        return Err(SourceError::Binding);
    }
    let mut plans = BTreeSet::new();
    for plan in &wire.plans {
        if !plans.insert(&plan.node)
            || !selected.contains(&plan.node)
            || !plan.matches(task).map_err(|_| SourceError::Contract)?
        {
            return Err(SourceError::Binding);
        }
    }
    Ok(())
}
