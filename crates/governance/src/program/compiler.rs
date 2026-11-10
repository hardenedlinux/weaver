// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Fixed compiled Scheme application on the existing thread-affine Gerbil owner.
use super::linked;
use crate::{DerivationOutput, OwnedSource, SourceError, materialize_source, root_source};
use gerbil_scheme::{
    BigIntegerBuffer, CollectionKind, GerbilRuntime, RootedObjectBatch, RootedSchemeObject,
    SchemeScalar,
};
use std::{
    collections::BTreeMap,
    sync::{Arc, Weak},
};

/// Neither this owner nor its Gerbil runtime is Send. Construct it on the tracked
/// blocking thread; no borrowed root/object crosses a queue or await.
pub struct SchemeCompiler {
    runtime: GerbilRuntime,
    compact_governor: bool,
    named_governor_result: bool,
    packed_governor_facts: bool,
    packed_node_indices: BTreeMap<String, u8>,
    governor_generation: u64,
    governor_topology: Weak<crate::GovernorTopology>,
}
impl SchemeCompiler {
    /// Initialize the linked approved graph and require an installed producer.
    pub fn initialize() -> Result<Self, SourceError> {
        if weaver_policy_ffi::weaver_policy_abi_v1() != 0x0001_0000 {
            return Err(SourceError::Scheme);
        }
        let runtime = linked::initialize().map_err(|_| SourceError::Scheme)?;
        if !linked::ready(&runtime).map_err(|_| SourceError::Scheme)? {
            return Err(SourceError::Contract);
        }
        Ok(Self {
            runtime,
            compact_governor: std::env::var("WEAVER_TEST_GOVERNOR_RETAINED").as_deref() == Ok("1")
                && std::env::var("WEAVER_TEST_GOVERNOR_FULL_CUT").as_deref() != Ok("1"),
            named_governor_result: std::env::var("WEAVER_TEST_GOVERNOR_NAMED_RESULT").as_deref()
                == Ok("1"),
            packed_governor_facts: std::env::var("WEAVER_TEST_GOVERNOR_PACKED_FACTS").as_deref()
                == Ok("1"),
            packed_node_indices: BTreeMap::new(),
            governor_generation: 0,
            governor_topology: Weak::new(),
        })
    }
    /// Compose trusted startup data before sealing its exact original binding.
    /// This does not authenticate source authority or publish any object.
    pub fn compose(
        &mut self,
        configuration: &crate::SourceComposition,
    ) -> Result<OwnedSource, SourceError> {
        let input = crate::scheme_input::records::root_composition(&self.runtime, configuration)?;
        let output = linked::compose(&self.runtime, &input).map_err(|_| SourceError::Scheme)?;
        let selected = materialize_source(output)?;
        configuration.validate_selected(&selected)?;
        Ok(selected)
    }
    pub fn evaluate(&mut self, input: &crate::Derivation) -> Result<DerivationOutput, SourceError> {
        match input {
            crate::Derivation::Composition(configuration) => {
                self.compose(configuration).map(DerivationOutput::Source)
            }
            crate::Derivation::Governor(cut) => self.derive(cut),
            crate::Derivation::FactImpact { root, dependencies } => {
                let input = crate::scheme_input::values::Input::new(&self.runtime);
                let root = input.record(vec![
                    ("root", input.text(root)?),
                    ("dependencies", input.edges(dependencies)?),
                ])?;
                let output =
                    linked::fact_impact(&self.runtime, &root).map_err(|_| SourceError::Scheme)?;
                crate::scheme::materialize(output).map(DerivationOutput::Nodes)
            }
        }
    }
    pub fn derive(&mut self, cut: &crate::GovernorCut) -> Result<DerivationOutput, SourceError> {
        let started = crate::host::governor_timing().then(std::time::Instant::now);
        let topology = &cut.topology;
        let send_topology = self.begin_governor_binding(topology);
        let input = crate::scheme_input::values::Input::new(&self.runtime);
        let indexed_result = self.compact_governor && !self.named_governor_result;
        let packed_facts = indexed_result && self.packed_governor_facts && !send_topology;
        let mut fields =
            governor_fact_fields(&input, cut, packed_facts, &mut self.packed_node_indices)?;
        if send_topology {
            fields.extend(governor_topology_fields(&input, topology)?);
        }
        append_governor_binding(
            &input,
            &mut fields,
            self.compact_governor,
            send_topology,
            indexed_result,
            &mut self.governor_generation,
        )?;
        let (output, called) =
            call_prepared_governor(&self.runtime, input.record(fields)?, started.is_some())?;
        let result = accept_governor_reply(
            output,
            indexed_result,
            self.compact_governor,
            self.governor_generation,
            topology,
            &mut self.governor_topology,
        );
        trace_governor_ffi(
            governor_transport(self.compact_governor, send_topology),
            indexed_result,
            packed_facts,
            started,
            called,
        );
        result
    }
    fn begin_governor_binding(&mut self, topology: &Arc<crate::GovernorTopology>) -> bool {
        let previous = std::mem::take(&mut self.governor_topology);
        let send_topology =
            !self.compact_governor || !Weak::ptr_eq(&previous, &Arc::downgrade(topology));
        if send_topology {
            self.packed_node_indices.clear();
        }
        send_topology
    }
    /// Compilation is inert preparation; the source lane independently binds
    /// this result to its retained original before any caller can claim it.
    pub fn compile(&mut self, original: &OwnedSource) -> Result<OwnedSource, SourceError> {
        self.compile_bound(original, None)
    }
    /// The source lane owns this monotonic token for the duration of capture.
    pub fn compile_cancellable(
        &mut self,
        original: &OwnedSource,
        cancel: &tokio_util::sync::CancellationToken,
    ) -> Result<OwnedSource, SourceError> {
        self.compile_bound(original, Some(cancel))
    }
    fn compile_bound(
        &mut self,
        original: &OwnedSource,
        shutdown: Option<&tokio_util::sync::CancellationToken>,
    ) -> Result<OwnedSource, SourceError> {
        let input = root_source(&self.runtime, original)?;
        let output =
            linked::capture(&self.runtime, &input, shutdown).map_err(|_| SourceError::Scheme)?;
        materialize_source(output)
    }
}

fn call_prepared_governor<'r>(
    runtime: &'r GerbilRuntime,
    input: RootedSchemeObject<'r>,
    timing: bool,
) -> Result<
    (
        RootedSchemeObject<'r>,
        Option<(std::time::Instant, std::time::Instant)>,
    ),
    SourceError,
> {
    let input_done = timing.then(std::time::Instant::now);
    let output = linked::derive(runtime, &input).map_err(|_| SourceError::Scheme)?;
    let ffi_done = timing.then(std::time::Instant::now);
    Ok((output, input_done.zip(ffi_done)))
}

fn accept_governor_reply(
    output: RootedSchemeObject<'_>,
    indexed: bool,
    compact: bool,
    binding: u64,
    topology: &Arc<crate::GovernorTopology>,
    retained: &mut Weak<crate::GovernorTopology>,
) -> Result<DerivationOutput, SourceError> {
    let result = if indexed {
        materialize_indices(output, binding, topology.nodes.len()).map(DerivationOutput::Indices)
    } else {
        crate::scheme::materialize(output).map(DerivationOutput::Nodes)
    };
    if compact && result.is_ok() {
        *retained = Arc::downgrade(topology);
    }
    result
}

fn governor_transport(compact: bool, send_topology: bool) -> &'static str {
    match (compact, send_topology) {
        (false, _) => "full",
        (true, true) => "bind",
        (true, false) => "compact",
    }
}

fn append_governor_binding<'r>(
    input: &crate::scheme_input::values::Input<'r>,
    fields: &mut Vec<(&'static str, RootedSchemeObject<'r>)>,
    compact: bool,
    send_topology: bool,
    indexed: bool,
    generation: &mut u64,
) -> Result<(), SourceError> {
    if compact {
        if send_topology {
            *generation = generation.checked_add(1).ok_or(SourceError::Bound)?;
        }
        fields.push(("topology_binding", input.number(*generation)?));
    }
    if indexed {
        fields.push(("indexed_result", input.number(1)?));
    }
    Ok(())
}

fn governor_fact_fields<'r>(
    input: &crate::scheme_input::values::Input<'r>,
    cut: &crate::GovernorCut,
    packed: bool,
    indices: &mut BTreeMap<String, u8>,
) -> Result<Vec<(&'static str, RootedSchemeObject<'r>)>, SourceError> {
    if packed {
        if indices.is_empty() {
            *indices = cut
                .topology
                .nodes
                .iter()
                .enumerate()
                .map(|(index, node)| {
                    u8::try_from(index)
                        .map(|index| (node.clone(), index))
                        .map_err(|_| SourceError::Bound)
                })
                .collect::<Result<_, _>>()?;
        }
        let bytes = pack_governor_facts(cut, indices)?;
        return Ok(vec![("packed_facts", input.bytes_vector(&bytes)?)]);
    }
    Ok(vec![
        ("complete", input.strings(&cut.complete)?),
        ("available", input.strings(&cut.available)?),
        ("pending", input.strings(&cut.pending)?),
        ("choice_result", input.strings(&cut.choice_result)?),
        ("choice_decided", input.strings(&cut.choice_decided)?),
        ("nested_results", input.edges(&cut.nested_results)?),
        ("nested_decisions", input.edges(&cut.nested_decisions)?),
    ])
}

fn governor_topology_fields<'r>(
    input: &crate::scheme_input::values::Input<'r>,
    topology: &crate::GovernorTopology,
) -> Result<[(&'static str, RootedSchemeObject<'r>); 5], SourceError> {
    Ok([
        ("nodes", input.strings(&topology.nodes)?),
        ("edges", input.edges(&topology.edges)?),
        ("choice_arms", input.strings(&topology.choice_arms)?),
        ("choice_join", input.strings(&topology.choice_join)?),
        (
            "nested_selectors",
            input.vector(
                topology
                    .nested_selectors
                    .iter()
                    .map(|row| input.strings(row))
                    .collect::<Result<Vec<_>, _>>()?,
            )?,
        ),
    ])
}

fn trace_governor_ffi(
    transport: &str,
    indexed: bool,
    packed: bool,
    started: Option<std::time::Instant>,
    called: Option<(std::time::Instant, std::time::Instant)>,
) {
    if let (Some(started), Some((input_done, ffi_done))) = (started, called) {
        let output_ns = ffi_done.elapsed().as_nanos();
        let result = if indexed { "indexed" } else { "named" };
        let facts = if packed { "packed" } else { "named" };
        eprintln!("weaver-governor-transport mode={transport}");
        eprintln!("weaver-governor-result mode={result}");
        eprintln!("weaver-governor-facts mode={facts}");
        eprintln!(
            "weaver-governor-ffi input_ns={} call_ns={} output_ns={}",
            input_done.duration_since(started).as_nanos(),
            ffi_done.duration_since(input_done).as_nanos(),
            output_ns
        );
    }
}

fn relation_count<T>(rows: &[T]) -> Result<u8, SourceError> {
    if rows.len() > 64 {
        return Err(SourceError::Bound);
    }
    Ok(rows.len() as u8)
}

fn route_tag(value: &str) -> Result<u8, SourceError> {
    match value {
        "left" => Ok(0),
        "right" => Ok(1),
        _ => Err(SourceError::Contract),
    }
}

fn pack_node_relation(
    bytes: &mut Vec<u8>,
    rows: &[String],
    indices: &BTreeMap<String, u8>,
) -> Result<(), SourceError> {
    bytes.push(relation_count(rows)?);
    for name in rows {
        bytes.push(*indices.get(name).ok_or(SourceError::Contract)?);
    }
    Ok(())
}

fn pack_route_relation(
    bytes: &mut Vec<u8>,
    rows: &[(String, String)],
    indices: &BTreeMap<String, u8>,
) -> Result<(), SourceError> {
    bytes.push(relation_count(rows)?);
    for (name, result) in rows {
        bytes.extend([
            *indices.get(name).ok_or(SourceError::Contract)?,
            route_tag(result)?,
        ]);
    }
    Ok(())
}

/// Seven length-prefixed relation groups in the order used by the Scheme
/// decoder. Node identities are positions in the already bound topology.
fn pack_governor_facts(
    cut: &crate::GovernorCut,
    indices: &BTreeMap<String, u8>,
) -> Result<Vec<u8>, SourceError> {
    let mut bytes = Vec::with_capacity(
        7 + cut.complete.len()
            + cut.available.len()
            + cut.pending.len()
            + cut.choice_result.len()
            + cut.choice_decided.len()
            + 2 * (cut.nested_results.len() + cut.nested_decisions.len()),
    );
    for rows in [&cut.complete, &cut.available, &cut.pending] {
        pack_node_relation(&mut bytes, rows, indices)?;
    }
    bytes.push(relation_count(&cut.choice_result)?);
    for result in &cut.choice_result {
        bytes.push(route_tag(result)?);
    }
    pack_node_relation(&mut bytes, &cut.choice_decided, indices)?;
    for rows in [&cut.nested_results, &cut.nested_decisions] {
        pack_route_relation(&mut bytes, rows, indices)?;
    }
    Ok(bytes)
}

/// The bound reply is one generation followed by at most 64 node indices.
/// Borrow the SDK snapshot instead of allocating a root and a general integer
/// buffer per element. No Scheme reference escapes this synchronous owner call.
fn materialize_indices(
    output: RootedSchemeObject<'_>,
    binding: u64,
    node_count: usize,
) -> Result<Vec<usize>, SourceError> {
    if node_count > 64 {
        return Err(SourceError::Bound);
    }
    let sequence = output
        .into_collection(CollectionKind::Vector)
        .map_err(|_| SourceError::Contract)?;
    // Include the binding: a full 64-node result legitimately has 65 elements.
    if sequence.is_empty() || sequence.len() > node_count + 1 {
        return Err(SourceError::Contract);
    }
    let mut entries = RootedObjectBatch::default();
    sequence
        .copy_into(&mut entries)
        .map_err(|_| SourceError::Scheme)?;
    let mut observed = BigIntegerBuffer::default();
    entries
        .get(0)
        .ok_or(SourceError::Contract)?
        .copy_big_integer(&mut observed)
        .map_err(|_| SourceError::Contract)?;
    let observed = observed.value();
    if observed.is_negative() || observed.magnitude().len() > 8 {
        return Err(SourceError::Contract);
    }
    let mut bytes = [0; 8];
    bytes[..observed.magnitude().len()].copy_from_slice(observed.magnitude());
    if u64::from_le_bytes(bytes) != binding {
        return Err(SourceError::Contract);
    }
    (1..entries.len())
        .map(|position| {
            match entries
                .get(position)
                .ok_or(SourceError::Contract)?
                .scalar()
                .map_err(|_| SourceError::Contract)?
            {
                SchemeScalar::Fixnum(index) => usize::try_from(index)
                    .ok()
                    .filter(|&index| index < node_count)
                    .ok_or(SourceError::Contract),
                _ => Err(SourceError::Contract),
            }
        })
        .collect()
}

#[cfg(test)]
fn bound_indices(
    reply: Vec<u64>,
    binding: u64,
    node_count: usize,
) -> Result<Vec<usize>, SourceError> {
    let (observed, indices) = reply.split_first().ok_or(SourceError::Contract)?;
    if *observed != binding || indices.len() > node_count {
        return Err(SourceError::Contract);
    }
    indices
        .iter()
        .map(|&index| {
            usize::try_from(index)
                .ok()
                .filter(|&index| index < node_count)
                .ok_or(SourceError::Contract)
        })
        .collect()
}

#[cfg(test)]
#[test]
fn governor_indices_reject_stale_binding_and_foreign_node() {
    assert_eq!(
        bound_indices(vec![3, 1, 0], 3, 2).expect("valid bound indices"),
        [1, 0]
    );
    assert!(bound_indices(vec![2, 1], 3, 2).is_err());
    assert!(bound_indices(vec![3, 2], 3, 2).is_err());
    assert!(bound_indices(Vec::new(), 3, 2).is_err());
}

#[cfg(test)]
#[test]
fn rooted_governor_indices_preserve_full_width_binding_and_all_64_candidates() {
    let mut compiler = SchemeCompiler::initialize().expect("approved linked application");
    composition_uses_scheme_then_rust_seals_the_exact_original(&mut compiler);
    let vm = &compiler.runtime;
    let input = crate::scheme_input::values::Input::new(vm);
    let vector = |values: Vec<RootedSchemeObject<'_>>| {
        vm.collection_from_objects(CollectionKind::Vector, &values.iter().collect::<Vec<_>>())
            .expect("native vector")
            .into_object()
    };
    let reply = |values: &[u64]| {
        vector(
            values
                .iter()
                .map(|&value| input.number(value).expect("exact integer"))
                .collect(),
        )
    };
    for binding in [0, 3, u64::MAX] {
        for count in [0, 1, 2, 32, 63, 64] {
            let mut values = vec![binding];
            values.extend((0..count as u64).rev());
            let expected = bound_indices(values.clone(), binding, count).expect("reference");
            assert_eq!(
                materialize_indices(reply(&values), binding, count).expect("typed result"),
                expected
            );
            if count < 64 {
                assert_eq!(
                    crate::scheme::materialize::<Vec<u64>>(reply(&values)).expect("general result"),
                    values
                );
            } else {
                assert!(matches!(
                    crate::scheme::materialize::<Vec<u64>>(reply(&values)),
                    Err(SourceError::Bound)
                ));
            }
        }
    }
    // Repeated candidates retain the previous contract; the Session consumer
    // sorts/deduplicates them before any deciding transaction.
    assert_eq!(
        materialize_indices(reply(&[3, 1, 1]), 3, 2).expect("repeated candidate"),
        [1, 1]
    );
    for values in [&[][..], &[2, 1], &[3, 2], &[3, u64::MAX], &[3, 0, 1, 0]] {
        assert!(materialize_indices(reply(values), 3, 2).is_err());
    }
    assert!(materialize_indices(reply(&[3]), 3, 65).is_err());
    for value in [
        SchemeScalar::Boolean(false),
        SchemeScalar::Fixnum(-1),
        SchemeScalar::Flonum(1.0),
        SchemeScalar::Char('a'),
    ] {
        let malformed = || vm.scalar_object(value).expect("malformed scalar");
        assert!(materialize_indices(malformed(), 3, 2).is_err());
        assert!(
            materialize_indices(
                vector(vec![input.number(3).expect("binding"), malformed()]),
                3,
                2
            )
            .is_err()
        );
        assert!(materialize_indices(vector(vec![malformed()]), 3, 2).is_err());
    }
    let wide = gerbil_scheme::BinaryInteger::new(false, vec![1; 9]).expect("wide integer");
    assert!(
        materialize_indices(
            vector(vec![vm.big_integer(&wide).expect("wide root")]),
            3,
            2
        )
        .is_err()
    );
    // A decline cannot poison the owner or replay the previous successful set.
    assert_eq!(
        materialize_indices(reply(&[4, 0]), 4, 2).expect("replacement binding"),
        [0]
    );
}

#[cfg(test)]
fn composition_uses_scheme_then_rust_seals_the_exact_original(compiler: &mut SchemeCompiler) {
    use crate::{RoutingCandidate, RoutingSelection, SourceComposition};
    let original = crate::source_fixture::source();
    let mut raw = original.clone();
    raw.tasks[0].body_digests.clear();
    raw.tasks[0].stream_contracts.clear();
    raw.plans.clear();
    let routing = original
        .plans
        .iter()
        .map(|plan| RoutingSelection {
            node: plan.node.clone(),
            allowed_modules: vec!["approved".into()],
            required: vec!["text".into()],
            max_latency_ms: 100,
            max_procurement_cost: 4,
            user_token_rates: [0; 4],
            candidates: vec![RoutingCandidate {
                module: "approved".into(),
                capabilities: vec!["text".into()],
                latency_ms: 10,
                procurement_rates: [0; 4],
                token_bounds: [0, 0, 0, 32],
                plan: plan.clone(),
            }],
        })
        .collect();
    let mut configuration = SourceComposition {
        source: raw,
        routing,
    };
    let selected = compiler
        .compose(&configuration)
        .expect("Scheme composition");
    assert!(selected.data() == &original);
    let expected = crate::SourceExpectation::capture(&selected);
    assert!(expected.bind(selected.clone()).is_ok());
    configuration.routing[0].allowed_modules.clear();
    assert!(compiler.compose(&configuration).is_err());
    configuration.routing[0]
        .allowed_modules
        .push("approved".into());
    configuration.routing[0].candidates[0].plan.body = "{}".into();
    assert!(compiler.compose(&configuration).is_err());
}
