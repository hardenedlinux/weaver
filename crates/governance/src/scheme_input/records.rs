// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Exhaustive concrete source fields; record names are symbols, map identifiers strings.
use super::values::{Input, Object, Result};
use crate::{OwnedSource, SourceData, SourceSelection};
use gerbil_scheme::GerbilRuntime;
use weaver_contracts::{ProviderPlan, ProviderProfile, ProviderRoute, Publication, Task};

/// Root an already validated original on its VM owner thread. No JSON encoding,
/// raw object word, retained callback or authority is created. Partial construction
/// failure drops owned roots naturally; bounds cover traversal, not hostile VM code.
pub fn root_source<'r>(vm: &'r GerbilRuntime, source: &OwnedSource) -> Result<Object<'r>> {
    root_source_data(&Input::new(vm), source.data())
}

fn root_source_data<'r>(input: &Input<'r>, source: &SourceData) -> Result<Object<'r>> {
    let SourceData {
        governance,
        tasks,
        plans,
        publication,
    } = source;
    let selection = root_selection(input, governance)?;
    let tasks = input.vector(
        tasks
            .iter()
            .map(|task| root_task(input, task))
            .collect::<Result<Vec<_>>>()?,
    )?;
    let plans = input.vector(
        plans
            .iter()
            .map(|plan| root_plan(input, plan))
            .collect::<Result<Vec<_>>>()?,
    )?;
    let publication = root_publication(input, publication)?;
    input.record(vec![
        ("governance", selection),
        ("tasks", tasks),
        ("plans", plans),
        ("publication", publication),
    ])
}

fn root_selection<'r>(input: &Input<'r>, governance: &SourceSelection) -> Result<Object<'r>> {
    let SourceSelection {
        schema,
        family,
        open_nodes,
        workflow_edges,
        workflow_selectors,
    } = governance;
    let mut selection = vec![
        ("schema", input.text(schema)?),
        ("family", input.text(family)?),
        ("open_nodes", input.strings(open_nodes)?),
    ];
    if !workflow_edges.is_empty() {
        selection.push(("workflow_edges", input.edges(workflow_edges)?));
    }
    if !workflow_selectors.is_empty() {
        selection.push((
            "workflow_selectors",
            input.vector(
                workflow_selectors
                    .iter()
                    .map(|row| input.strings(row))
                    .collect::<Result<Vec<_>>>()?,
            )?,
        ));
    }
    input.record(selection)
}

fn root_publication<'r>(input: &Input<'r>, publication: &Publication) -> Result<Object<'r>> {
    let Publication {
        operation_id,
        expected_revision,
        fence,
        policy,
        schema,
    } = publication;
    let mut fields = vec![
        ("operation_id", input.text(operation_id)?),
        ("fence", input.number(*fence)?),
        ("policy", input.text(policy)?),
        ("schema", input.text(schema)?),
    ];
    if let Some(revision) = *expected_revision {
        fields.push(("expected_revision", input.number(revision)?));
    }
    input.record(fields)
}
fn root_task<'r>(input: &Input<'r>, task: &Task) -> Result<Object<'r>> {
    let Task {
        family,
        principal,
        profile,
        provider_profile,
        nodes,
        targets,
        models,
        endpoints,
        body_digests,
        stream_contracts,
        node_cost_bounds,
        budget,
    } = task;
    let mut fields = vec![
        ("family", input.text(family)?),
        ("principal", input.text(principal)?),
        ("profile", input.text(profile)?),
        ("nodes", input.strings(nodes)?),
        ("targets", input.strings(targets)?),
        ("models", input.strings(models)?),
        ("endpoints", input.texts(endpoints)?),
        ("body_digests", input.texts(body_digests)?),
        ("stream_contracts", input.texts(stream_contracts)?),
        ("node_cost_bounds", input.numbers(node_cost_bounds)?),
        ("budget", input.number(*budget)?),
    ];
    if let Some(profile) = provider_profile {
        let ProviderProfile {
            id,
            protocol,
            max_output_tokens,
            max_messages,
            max_body_bytes,
        } = profile;
        fields.push((
            "provider_profile",
            input.record(vec![
                ("id", input.text(id)?),
                ("protocol", input.text(protocol)?),
                ("max_output_tokens", input.number(*max_output_tokens)?),
                ("max_messages", input.number(*max_messages)?),
                ("max_body_bytes", input.number(*max_body_bytes)?),
            ])?,
        ));
    }
    input.record(fields)
}
fn root_plan<'r>(input: &Input<'r>, plan: &ProviderPlan) -> Result<Object<'r>> {
    let ProviderPlan {
        family,
        node,
        profile,
        profile_commitment,
        model,
        body,
        ceiling,
        revision,
        fence,
        routes,
    } = plan;
    let routes = routes
        .iter()
        .map(|route| {
            let ProviderRoute { target, endpoint } = route;
            input.record(vec![
                ("target", input.text(target)?),
                ("endpoint", input.text(endpoint)?),
            ])
        })
        .collect::<Result<Vec<_>>>()?;
    input.record(vec![
        ("family", input.text(family)?),
        ("node", input.text(node)?),
        ("profile", input.text(profile)?),
        ("profile_commitment", input.text(profile_commitment)?),
        ("model", input.text(model)?),
        ("body", input.text(body)?),
        ("ceiling", input.number(*ceiling)?),
        ("revision", input.number(*revision)?),
        ("fence", input.number(*fence)?),
        ("routes", input.vector(routes)?),
    ])
}

/// Prepare bounded facts and canonical commitments without choosing a candidate.
#[cfg(feature = "scheme-program")]
pub(crate) fn root_composition<'r>(
    vm: &'r GerbilRuntime,
    value: &crate::SourceComposition,
) -> Result<Object<'r>> {
    use crate::SourceError;
    let source = &value.source;
    if source.tasks.len() != 1
        || !source.plans.is_empty()
        || value.routing.is_empty()
        || value.routing.len() > 64
        || !source.tasks[0].body_digests.is_empty()
        || !source.tasks[0].stream_contracts.is_empty()
    {
        return Err(SourceError::Binding);
    }
    let input = Input::new(vm);
    let task = &source.tasks[0];
    let mut selections = Vec::new();
    for selection in &value.routing {
        if selection.candidates.is_empty() || selection.candidates.len() > 8 {
            return Err(SourceError::Bound);
        }
        let mut candidates = Vec::new();
        for candidate in &selection.candidates {
            let plan = &candidate.plan;
            if candidate
                .procurement_rates
                .iter()
                .chain(&candidate.token_bounds)
                .any(|value| *value > weaver_contracts::MAX_CREDITS)
            {
                continue;
            }
            let Ok(digest) = plan.digest() else { continue };
            let body = weaver_contracts::body_digest(&plan.body);
            let mut bound = task.clone();
            bound.body_digests.insert(plan.node.clone(), body.clone());
            bound
                .stream_contracts
                .insert(plan.node.clone(), digest.clone());
            let Ok(Some(facts)) = plan.binding(&bound) else {
                continue;
            };
            if facts.model != plan.model || candidate.token_bounds[3] < facts.output_token_limit {
                continue;
            }
            candidates.push(input.record(vec![
                ("module", input.text(&candidate.module)?),
                ("capabilities", input.strings(&candidate.capabilities)?),
                ("latency_ms", input.number(candidate.latency_ms)?),
                (
                    "procurement_rates",
                    numbers(&input, &candidate.procurement_rates)?,
                ),
                ("token_bounds", numbers(&input, &candidate.token_bounds)?),
                ("plan", root_plan(&input, plan)?),
                ("digest", input.text(&digest)?),
                ("body_digest", input.text(&body)?),
            ])?);
        }
        selections.push(input.record(vec![
            ("node", input.text(&selection.node)?),
            (
                "allowed_modules",
                input.strings(&selection.allowed_modules)?,
            ),
            ("required", input.strings(&selection.required)?),
            ("max_latency_ms", input.number(selection.max_latency_ms)?),
            (
                "max_procurement_cost",
                input.number(selection.max_procurement_cost)?,
            ),
            (
                "user_token_rates",
                numbers(&input, &selection.user_token_rates)?,
            ),
            ("candidates", input.vector(candidates)?),
        ])?);
    }
    input.record(vec![
        ("source", root_source_data(&input, source)?),
        ("routing", input.vector(selections)?),
    ])
}
#[cfg(feature = "scheme-program")]
fn numbers<'r>(input: &Input<'r>, values: &[u64]) -> Result<Object<'r>> {
    input.vector(
        values
            .iter()
            .map(|value| input.number(*value))
            .collect::<Result<Vec<_>>>()?,
    )
}
