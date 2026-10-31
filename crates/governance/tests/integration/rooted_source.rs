//! Typed fixture projection through SDK constructors; no JSON intermediary.
use gerbil_scheme::{
    BinaryInteger, CollectionKind, GerbilRuntime, IdentifierKind, RootedSchemeObject as Object,
    TableEquality,
};
use weaver_governance::SourceData;
fn text<'r>(vm: &'r GerbilRuntime, value: &str) -> Object<'r> {
    vm.string_from_utf8(value).expect("string").into_object()
}
fn number(vm: &GerbilRuntime, value: u64) -> Object<'_> {
    let mut bytes = value.to_le_bytes().to_vec();
    while bytes.last() == Some(&0) {
        bytes.pop();
    }
    vm.big_integer(&BinaryInteger::new(false, bytes).expect("canonical integer"))
        .expect("integer")
}
fn table<'r>(vm: &'r GerbilRuntime, fields: Vec<(&str, Object<'r>)>, symbols: bool) -> Object<'r> {
    let keys: Vec<_> = fields
        .iter()
        .map(|(key, _)| {
            if symbols {
                vm.intern_identifier(IdentifierKind::Symbol, key)
                    .expect("field")
            } else {
                text(vm, key)
            }
        })
        .collect();
    let entries: Vec<_> = keys
        .iter()
        .zip(fields.iter().map(|(_, value)| value))
        .collect();
    vm.hash_table(TableEquality::Structural, &entries)
        .expect("table")
}
fn list<'r>(vm: &'r GerbilRuntime, values: Vec<Object<'r>>) -> Object<'r> {
    vm.collection_from_objects(CollectionKind::Vector, &values.iter().collect::<Vec<_>>())
        .expect("vector")
        .into_object()
}
fn strings<'r>(vm: &'r GerbilRuntime, values: &[String]) -> Object<'r> {
    list(vm, values.iter().map(|v| text(vm, v)).collect())
}
fn texts<'r>(
    vm: &'r GerbilRuntime,
    values: &std::collections::BTreeMap<String, String>,
) -> Object<'r> {
    table(
        vm,
        values
            .iter()
            .map(|(k, v)| (k.as_str(), text(vm, v)))
            .collect(),
        false,
    )
}
pub fn source<'r>(vm: &'r GerbilRuntime, data: &SourceData) -> Object<'r> {
    let tasks = data
        .tasks
        .iter()
        .map(|t| {
            let p = t.provider_profile.as_ref().expect("profile");
            table(
                vm,
                vec![
                    ("family", text(vm, &t.family)),
                    ("principal", text(vm, &t.principal)),
                    ("profile", text(vm, &t.profile)),
                    (
                        "provider_profile",
                        table(
                            vm,
                            vec![
                                ("id", text(vm, &p.id)),
                                ("protocol", text(vm, &p.protocol)),
                                ("max_output_tokens", number(vm, p.max_output_tokens)),
                                ("max_messages", number(vm, p.max_messages)),
                                ("max_body_bytes", number(vm, p.max_body_bytes)),
                            ],
                            true,
                        ),
                    ),
                    ("nodes", strings(vm, &t.nodes)),
                    ("targets", strings(vm, &t.targets)),
                    ("models", strings(vm, &t.models)),
                    ("endpoints", texts(vm, &t.endpoints)),
                    ("body_digests", texts(vm, &t.body_digests)),
                    ("stream_contracts", texts(vm, &t.stream_contracts)),
                    (
                        "node_cost_bounds",
                        table(
                            vm,
                            t.node_cost_bounds
                                .iter()
                                .map(|(k, v)| (k.as_str(), number(vm, *v)))
                                .collect(),
                            false,
                        ),
                    ),
                    ("budget", number(vm, t.budget)),
                ],
                true,
            )
        })
        .collect();
    let plans = data
        .plans
        .iter()
        .map(|p| {
            table(
                vm,
                vec![
                    ("family", text(vm, &p.family)),
                    ("node", text(vm, &p.node)),
                    ("profile", text(vm, &p.profile)),
                    ("profile_commitment", text(vm, &p.profile_commitment)),
                    ("model", text(vm, &p.model)),
                    ("body", text(vm, &p.body)),
                    ("ceiling", number(vm, p.ceiling)),
                    ("revision", number(vm, p.revision)),
                    ("fence", number(vm, p.fence)),
                    (
                        "routes",
                        list(
                            vm,
                            p.routes
                                .iter()
                                .map(|r| {
                                    table(
                                        vm,
                                        vec![
                                            ("target", text(vm, &r.target)),
                                            ("endpoint", text(vm, &r.endpoint)),
                                        ],
                                        true,
                                    )
                                })
                                .collect(),
                        ),
                    ),
                ],
                true,
            )
        })
        .collect();
    let p = &data.publication;
    let mut publication = vec![
        ("operation_id", text(vm, &p.operation_id)),
        ("fence", number(vm, p.fence)),
        ("policy", text(vm, &p.policy)),
        ("schema", text(vm, &p.schema)),
    ];
    if let Some(revision) = p.expected_revision {
        publication.push(("expected_revision", number(vm, revision)));
    }
    table(
        vm,
        vec![
            (
                "governance",
                table(
                    vm,
                    vec![
                        ("schema", text(vm, &data.governance.schema)),
                        ("family", text(vm, &data.governance.family)),
                        ("open_nodes", strings(vm, &data.governance.open_nodes)),
                    ],
                    true,
                ),
            ),
            ("tasks", list(vm, tasks)),
            ("plans", list(vm, plans)),
            ("publication", table(vm, publication, true)),
        ],
        true,
    )
}

/// Rebuild a real native table with one deliberate field corruption.
pub fn corrupt<'r>(vm: &'r GerbilRuntime, root: &Object<'r>, fault: u8) -> Object<'r> {
    use gerbil_scheme::{IdentifierBuffer, RootedObjectBatch, SchemeScalar};
    let mut batch = RootedObjectBatch::default();
    root.copy_table_entries(&mut batch).expect("snapshot");
    let mut entries = Vec::new();
    for index in (0..batch.len()).step_by(2) {
        let mut key = batch.root_element(index).expect("key");
        let mut value = batch.root_element(index + 1).expect("value");
        let mut name = IdentifierBuffer::default();
        key.as_ref()
            .copy_identifier_names(&mut name)
            .expect("symbol");
        let name = name.get(0).expect("name").1;
        if name == "fence" {
            value = match fault {
                0 => vm
                    .scalar_object(SchemeScalar::Boolean(false))
                    .expect("false"),
                1 => vm.nil_object().expect("nil"),
                2 => vm.scalar_object(SchemeScalar::Flonum(1.0)).expect("float"),
                _ => value,
            };
        }
        if fault == 3 {
            key = text(vm, name);
        }
        entries.push((key, value));
    }
    if fault == 4 {
        entries.push((
            vm.intern_identifier(IdentifierKind::Symbol, "approved")
                .expect("extra"),
            vm.scalar_object(SchemeScalar::Boolean(true)).expect("true"),
        ));
    }
    vm.hash_table(
        TableEquality::Structural,
        &entries.iter().map(|(k, v)| (k, v)).collect::<Vec<_>>(),
    )
    .expect("corrupt table")
}
pub fn publication<'r>(vm: &'r GerbilRuntime, data: &SourceData, fault: u8) -> Object<'r> {
    let root = source(vm, data);
    let mut batch = gerbil_scheme::RootedObjectBatch::default();
    root.copy_table_entries(&mut batch)
        .expect("source snapshot");
    let mut entries = Vec::new();
    for index in (0..batch.len()).step_by(2) {
        let key = batch.root_element(index).expect("field");
        let mut value = batch.root_element(index + 1).expect("value");
        let mut name = gerbil_scheme::IdentifierBuffer::default();
        key.as_ref()
            .copy_identifier_names(&mut name)
            .expect("field name");
        if name.get(0).expect("field").1 == "publication" {
            value = corrupt(vm, &value, fault);
        }
        entries.push((key, value));
    }
    vm.hash_table(
        TableEquality::Structural,
        &entries.iter().map(|(k, v)| (k, v)).collect::<Vec<_>>(),
    )
    .expect("source fault")
}
