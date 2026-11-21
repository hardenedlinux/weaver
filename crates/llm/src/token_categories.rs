// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Provider usage normalization, independent of pricing and settlement authority.
use crate::Error;
use serde_json::Value;

/// Disjoint reported token categories, available only after a validated terminal.
/// These counts are observations; the issuer and ledger retain settlement authority.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TokenCategories {
    /// Input excluding cache reads and cache writes.
    pub ordinary_input: u64,
    /// Input retrieved from cache.
    pub cache_read_input: u64,
    /// Input written to cache.
    pub cache_write_input: u64,
    /// Inclusive output, including any reported reasoning tokens.
    pub output: u64,
}

impl TokenCategories {
    pub(crate) fn openai(value: &Value, chat: bool) -> Result<Self, Error> {
        let input = required(
            value,
            if chat {
                "prompt_tokens"
            } else {
                "input_tokens"
            },
        )?;
        let output = required(
            value,
            if chat {
                "completion_tokens"
            } else {
                "output_tokens"
            },
        )?;
        let details = &value[if chat {
            "prompt_tokens_details"
        } else {
            "input_tokens_details"
        }];
        if !details.is_null() && !details.is_object() {
            return Err(Error::Response);
        }
        let read = optional(details, "cached_tokens")?.unwrap_or(0);
        let write = optional(details, "cache_write_tokens")?.unwrap_or(0);
        let ordinary_input = input
            .checked_sub(read)
            .and_then(|v| v.checked_sub(write))
            .ok_or(Error::Response)?;
        let total = input.checked_add(output).ok_or(Error::Response)?;
        if optional(value, "total_tokens")?.is_some_and(|n| n != total) {
            return Err(Error::Response);
        }
        Ok(Self {
            ordinary_input,
            cache_read_input: read,
            cache_write_input: write,
            output,
        })
    }

    pub(crate) fn anthropic_start(value: &Value) -> Result<Self, Error> {
        let categories = Self {
            ordinary_input: required(value, "input_tokens")?,
            cache_read_input: optional(value, "cache_read_input_tokens")?.unwrap_or(0),
            cache_write_input: optional(value, "cache_creation_input_tokens")?.unwrap_or(0),
            output: required(value, "output_tokens")?,
        };
        categories.checked()?;
        Ok(categories)
    }

    pub(crate) fn anthropic_delta(mut self, value: &Value) -> Result<Self, Error> {
        // Message delta usage is cumulative. Missing/null fields preserve the
        // original category; they do not clear it or add another delta.
        if let Some(n) = optional(value, "input_tokens")? {
            self.ordinary_input = n;
        }
        if let Some(n) = optional(value, "cache_read_input_tokens")? {
            self.cache_read_input = n;
        }
        if let Some(n) = optional(value, "cache_creation_input_tokens")? {
            self.cache_write_input = n;
        }
        if let Some(n) = optional(value, "output_tokens")? {
            self.output = n;
        }
        self.checked()?;
        Ok(self)
    }

    fn checked(&self) -> Result<(), Error> {
        self.ordinary_input
            .checked_add(self.cache_read_input)
            .and_then(|n| n.checked_add(self.cache_write_input))
            .and_then(|n| n.checked_add(self.output))
            .ok_or(Error::Response)?;
        Ok(())
    }
}

fn required(value: &Value, field: &str) -> Result<u64, Error> {
    value[field].as_u64().ok_or(Error::Response)
}

fn optional(value: &Value, field: &str) -> Result<Option<u64>, Error> {
    match value.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(number) => number.as_u64().map(Some).ok_or(Error::Response),
    }
}

#[cfg(test)]
#[path = "../tests/unit/token_categories.rs"]
mod tests;
