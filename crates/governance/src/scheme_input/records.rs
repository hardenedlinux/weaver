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
    let input = Input::new(vm);
    let SourceData {
        governance,
        tasks,
        plans,
        publication,
    } = source.data();
    let selection = root_selection(&input, governance)?;
    let tasks = input.vector(
        tasks
            .iter()
            .map(|task| root_task(&input, task))
            .collect::<Result<Vec<_>>>()?,
    )?;
    let plans = input.vector(
        plans
            .iter()
            .map(|plan| root_plan(&input, plan))
            .collect::<Result<Vec<_>>>()?,
    )?;
    let publication = root_publication(&input, publication)?;
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
