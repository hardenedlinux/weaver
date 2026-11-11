// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Decode the deployed source bundle into the existing Scheme input.
use serde::Deserialize;
use serde_json::Value;
use std::{io::Read, path::Path};
use weaver_contracts::{DeltaReview, Error, ProviderPlan, Publication, Result, Task};
use weaver_governance::{RoutingSelection, SourceComposition, SourceData, SourceSelection};

const MAX_FILE_BYTES: usize = weaver_governance::MAX_SOURCE_BYTES;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Bundle {
    #[serde(default)]
    select_on_request: bool,
    routing: Option<Vec<RoutingSelection>>,
    governance: SourceSelection,
    tasks: Vec<Task>,
    plans: Option<Vec<ProviderPlan>>,
    publication: FilePublication,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FilePublication {
    operation_id: String,
    expected_revision: Option<u64>,
    fence: u64,
    policy: String,
    schema: String,
    review: Option<DeltaReview>,
}

pub(crate) struct FileSource {
    pub(crate) input: SourceComposition,
    pub(crate) select_on_request: bool,
    pub(crate) review: Option<DeltaReview>,
}

pub(crate) fn load(path: &Path) -> Result<FileSource> {
    let format = path.extension().and_then(|extension| extension.to_str());
    if format.is_some_and(|extension| {
        ["ss", "scm"]
            .iter()
            .any(|name| extension.eq_ignore_ascii_case(name))
    }) {
        return Err(Error::Invalid(
            "Scheme deployment requires an approved producer",
        ));
    }
    let yaml = format.is_some_and(|extension| {
        extension.eq_ignore_ascii_case("yaml") || extension.eq_ignore_ascii_case("yml")
    });
    let mut document: Value = read_document(path, yaml, MAX_FILE_BYTES)?;
    normalize_bundle_collections(&mut document);
    let bundle: Bundle =
        serde_json::from_value(document).map_err(|_| Error::Invalid("source bundle fields"))?;
    let FilePublication {
        operation_id,
        expected_revision,
        fence,
        policy,
        schema,
        review,
    } = bundle.publication;
    let publication = Publication {
        operation_id,
        expected_revision,
        fence,
        policy,
        schema,
    };
    if let Some(evidence) = &review {
        evidence.validate()?;
        if evidence.review.publication.operation_id != publication.operation_id
            || evidence.review.publication.digest != publication.digest()?
        {
            return Err(Error::Invalid("source review binding"));
        }
    }
    let input = SourceComposition {
        source: SourceData {
            governance: bundle.governance,
            tasks: bundle.tasks,
            plans: bundle.plans.unwrap_or_default(),
            publication,
        },
        routing: bundle.routing.unwrap_or_default(),
    };
    Ok(FileSource {
        input,
        select_on_request: bundle.select_on_request,
        review,
    })
}

pub(crate) fn read_document<T: serde::de::DeserializeOwned>(
    path: &Path,
    yaml: bool,
    limit: usize,
) -> Result<T> {
    let mut data = Vec::new();
    std::fs::File::open(path)
        .map_err(|_| Error::Invalid("source data file"))?
        .take((limit + 1) as u64)
        .read_to_end(&mut data)
        .map_err(|_| Error::Invalid("source data read"))?;
    if data.is_empty() || data.len() > limit {
        return Err(Error::Invalid("source data bound"));
    }
    if !yaml {
        return weaver_contracts::decode_bounded(&data, limit)
            .map_err(|_| Error::Invalid("source data JSON"));
    }
    let text = std::str::from_utf8(&data).map_err(|_| Error::Invalid("source YAML encoding"))?;
    require_source_yaml_shape(text)?;
    let options = serde_saphyr::options! {
        merge_keys: serde_saphyr::MergeKeyPolicy::Error,
        duplicate_keys: serde_saphyr::DuplicateKeyPolicy::Error,
        strict_booleans: true,
        no_schema: true,
        budget: serde_saphyr::budget! {
            max_anchors: 0,
            max_aliases: 0,
            max_documents: 1,
            max_depth: 32,
            max_inclusion_depth: 0,
        },
    };
    serde_saphyr::from_str_with_options(text, options)
        .map_err(|_| Error::Invalid("source data YAML"))
}

fn require_source_yaml_shape(text: &str) -> Result<()> {
    use serde_saphyr::granit_parser::{Event, Parser};
    let mut document = false;
    let mut depth = 0;
    // The typed deserializer reads the first document and can interpret
    // non-core tags. Check the same parser's events before decoding data.
    for event in Parser::new_from_str(text) {
        let (event, _) = event.map_err(|_| Error::Invalid("source data YAML"))?;
        match event {
            Event::DocumentStart(..) if document => {
                return Err(Error::Invalid("one source YAML document required"));
            }
            Event::DocumentStart(..) => document = true,
            Event::Scalar(_, _, anchor, tag)
                if anchor != 0
                    || tag.as_ref().is_some_and(|tag| {
                        !matches!(tag.core_suffix(), Some("str" | "null" | "bool" | "int"))
                    }) =>
            {
                return Err(Error::Invalid("unsupported source YAML scalar"));
            }
            Event::SequenceStart(_, anchor, ref tag) | Event::MappingStart(_, anchor, ref tag) => {
                let expected_tag = if matches!(event, Event::SequenceStart(..)) {
                    "seq"
                } else {
                    "map"
                };
                depth += 1;
                if depth > 32
                    || anchor != 0
                    || tag
                        .as_ref()
                        .is_some_and(|tag| tag.core_suffix() != Some(expected_tag))
                {
                    return Err(Error::Invalid("source YAML structure"));
                }
            }
            Event::SequenceEnd | Event::MappingEnd => depth -= 1,
            Event::Alias(_) => return Err(Error::Invalid("source YAML alias")),
            _ => {}
        }
    }
    if !document {
        return Err(Error::Invalid("one source YAML document required"));
    }
    Ok(())
}

// The Go wire emits null for empty commitments and capability sets.
fn normalize_bundle_collections(document: &mut Value) {
    if let Some(tasks) = document.get_mut("tasks").and_then(Value::as_array_mut) {
        for task in tasks {
            normalize_null(task, "body_digests", Value::Object(Default::default()));
            normalize_null(task, "stream_contracts", Value::Object(Default::default()));
        }
    }
    if let Some(routing) = document.get_mut("routing").and_then(Value::as_array_mut) {
        routing.iter_mut().for_each(normalize_routing_collections);
    }
}

fn normalize_routing_collections(row: &mut Value) {
    normalize_null(row, "required", Value::Array(Vec::new()));
    if let Some(candidates) = row.get_mut("candidates").and_then(Value::as_array_mut) {
        for candidate in candidates {
            normalize_null(candidate, "capabilities", Value::Array(Vec::new()));
        }
    }
}

fn normalize_null(value: &mut Value, field: &str, empty: Value) {
    if let Some(entry) = value.get_mut(field).filter(|entry| entry.is_null()) {
        *entry = empty;
    }
}
