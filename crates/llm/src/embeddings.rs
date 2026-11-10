// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! OpenAI-compatible batch embeddings.

use serde::{Deserialize, Serialize};

use crate::Error;

/// A batch of text or pre-tokenized inputs for one embedding model.
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(untagged)]
pub enum EmbeddingInput<'a> {
    /// Raw text for each vector.
    Text(&'a [&'a str]),
    /// Provider tokenizer IDs for each vector.
    Tokens(&'a [&'a [u32]]),
}

/// Request to an OpenAI-compatible embeddings endpoint.
#[derive(Debug, Serialize)]
pub struct EmbeddingRequest<'a> {
    /// Exact provider model.
    pub model: &'a str,
    /// Ordered inputs for the batch.
    pub input: EmbeddingInput<'a>,
    /// Output dimension override for models that support it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dimensions: Option<usize>,
}

/// Provider-reported token accounting for an embedding batch.
#[derive(Debug, Deserialize, Eq, PartialEq)]
pub struct EmbeddingUsage {
    /// Number of input tokens.
    pub prompt_tokens: u64,
    /// Total billed tokens.
    pub total_tokens: u64,
}

/// A batch of vectors in the same order as the request inputs.
#[derive(Debug, PartialEq)]
pub struct Embeddings {
    /// Model reported by the provider.
    pub model: String,
    /// One vector per input.
    pub vectors: Vec<Vec<f32>>,
    /// Token accounting when supplied by the provider.
    pub usage: Option<EmbeddingUsage>,
}

impl EmbeddingRequest<'_> {
    pub(crate) fn encode(&self) -> Result<(Vec<u8>, usize), Error> {
        let count = match self.input {
            EmbeddingInput::Text(items) if items.iter().all(|item| !item.is_empty()) => items.len(),
            EmbeddingInput::Tokens(items) if items.iter().all(|item| !item.is_empty()) => {
                items.len()
            }
            _ => 0,
        };
        if self.model.trim().is_empty() || count == 0 || self.dimensions == Some(0) {
            return Err(Error::Request(
                "invalid embeddings model, batch or dimensions",
            ));
        }
        #[derive(Serialize)]
        struct Wire<'a> {
            #[serde(flatten)]
            request: &'a EmbeddingRequest<'a>,
            encoding_format: &'static str,
        }
        let body = serde_json::to_vec(&Wire {
            request: self,
            encoding_format: "float",
        })
        .map_err(|_| Error::Request("invalid embeddings request"))?;
        Ok((body, count))
    }
}

impl Embeddings {
    pub(crate) fn decode(
        body: &[u8],
        count: usize,
        dimensions: Option<usize>,
    ) -> Result<Self, Error> {
        #[derive(Deserialize)]
        struct Wire {
            model: String,
            data: Vec<Item>,
            usage: Option<EmbeddingUsage>,
        }
        #[derive(Deserialize)]
        struct Item {
            index: usize,
            embedding: Vec<f32>,
        }
        let mut wire: Wire = serde_json::from_slice(body).map_err(|_| Error::Response)?;
        if wire.model.is_empty() || wire.data.len() != count {
            return Err(Error::Response);
        }
        wire.data.sort_unstable_by_key(|item| item.index);
        let dimensions = dimensions.or_else(|| wire.data.first().map(|item| item.embedding.len()));
        if dimensions == Some(0)
            || wire.data.iter().enumerate().any(|(index, item)| {
                item.index != index
                    || Some(item.embedding.len()) != dimensions
                    || item.embedding.iter().any(|value| !value.is_finite())
            })
        {
            return Err(Error::Response);
        }
        Ok(Self {
            model: wire.model,
            vectors: wire.data.into_iter().map(|item| item.embedding).collect(),
            usage: wire.usage,
        })
    }
}
