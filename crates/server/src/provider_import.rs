// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Offline projection of reviewed LiteLLM inputs into the existing catalog record.
use crate::source_file::read_document;
use serde::Deserialize;
use std::{collections::BTreeMap, path::Path};
use weaver_contracts::{CatalogEntry, Error, ProviderCatalog, ProviderPlan, Result};

const MAX_IMPORT_BYTES: usize = 262_144;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Review {
    #[serde(default)]
    parent: String,
    bindings: BTreeMap<String, Binding>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Binding {
    plan: ProviderPlan,
    credential_reference: String,
    entry: CatalogEntry,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LiteLlm {
    model_list: Vec<Model>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Model {
    model_name: String,
    litellm_params: Parameters,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Parameters {
    model: String,
    api_base: String,
    api_key: String,
}

fn credential_reference(value: &str) -> bool {
    let Some(name) = value.strip_prefix("os.environ/") else {
        return false;
    };
    let mut bytes = name.bytes();
    name.len() <= 128
        && bytes
            .next()
            .is_some_and(|byte| byte.is_ascii_uppercase() || byte == b'_')
        && bytes.all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
}

pub(crate) fn proposal(source: &Path, yaml: bool, review: &Path) -> Result<Vec<u8>> {
    let source: LiteLlm = read_document(source, yaml, MAX_IMPORT_BYTES)?;
    let mut review: Review = read_document(review, false, weaver_contracts::MAX_BODY_BYTES * 2)?;
    if !review.parent.is_empty()
        && (review.parent.len() != 64
            || !review
                .parent
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()))
    {
        return Err(Error::Invalid("provider import parent digest"));
    }
    if source.model_list.is_empty()
        || source.model_list.len() > 256
        || source.model_list.len() != review.bindings.len()
    {
        return Err(Error::Invalid("provider import inventory"));
    }

    let mut entries = BTreeMap::new();
    for model in source.model_list {
        let binding = review
            .bindings
            .remove(&model.model_name)
            .filter(|_| !model.model_name.is_empty())
            .ok_or(Error::Invalid("provider import alias binding"))?;
        let parameters = model.litellm_params;
        let endpoint = format!(
            "{}/chat/completions",
            parameters
                .api_base
                .strip_suffix('/')
                .unwrap_or(&parameters.api_base)
        );
        if binding.plan.routes.len() != 1
            || binding.plan.routes[0].endpoint != endpoint
            || parameters.api_base.contains(['?', '#'])
            || parameters.model.strip_prefix("openai/") != Some(binding.plan.model.as_str())
            || parameters.api_key != binding.credential_reference
            || !credential_reference(&parameters.api_key)
        {
            return Err(Error::Invalid("provider import reviewed binding"));
        }
        weaver_broker::HttpsTransport::validate_endpoint(&endpoint)?;
        if entries
            .insert(binding.plan.digest()?, binding.entry)
            .is_some()
        {
            return Err(Error::Invalid("duplicate imported plan"));
        }
    }
    let record = ProviderCatalog {
        parent: review.parent,
        entries,
    }
    .record()?;
    if record.len() > MAX_IMPORT_BYTES {
        return Err(Error::Invalid("provider import output bound"));
    }
    Ok(record)
}
