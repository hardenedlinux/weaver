// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Supported sampling and response options under exact original request bytes.
use crate::{Error, Result};
use serde_json::{Map, Value};

pub(super) fn validate(body: &Map<String, Value>) -> Result<()> {
    for (key, low, high) in [
        ("temperature", 0.0, 2.0),
        ("top_p", 0.0, 1.0),
        ("frequency_penalty", -2.0, 2.0),
        ("presence_penalty", -2.0, 2.0),
    ] {
        if body
            .get(key)
            .is_some_and(|v| v.as_f64().is_none_or(|n| n < low || n > high))
        {
            return Err(Error::Invalid("sampling parameter"));
        }
    }
    if body.get("seed").is_some_and(|v| v.as_i64().is_none())
        || body.get("user").is_some_and(|v| !bounded_text(v))
    {
        return Err(Error::Invalid("provider metadata"));
    }
    if let Some(value) = body.get("stop") {
        let valid = bounded_text(value)
            || value.as_array().is_some_and(|items| {
                !items.is_empty() && items.len() <= 4 && items.iter().all(bounded_text)
            });
        if !valid {
            return Err(Error::Invalid("stop sequences"));
        }
    }
    if let Some(value) = body.get("stream_options")
        && (value
            .as_object()
            .is_none_or(|fields| fields.keys().any(|k| k != "include_usage"))
            || value.get("include_usage").is_some_and(|v| !v.is_boolean()))
    {
        return Err(Error::Invalid("stream options"));
    }
    if let Some(value) = body.get("response_format")
        && (value.as_object().is_none_or(|fields| fields.len() != 1)
            || value.get("type").and_then(Value::as_str) != Some("text"))
    {
        return Err(Error::Invalid("text response format required"));
    }
    Ok(())
}

fn bounded_text(value: &Value) -> bool {
    value
        .as_str()
        .is_some_and(|s| !s.is_empty() && s.len() <= 256)
}
