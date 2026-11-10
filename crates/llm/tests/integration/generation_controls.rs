// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{TestResult, messages};
use serde_json::Value;
use weaver_llm::{Options, Protocol, Request};

#[test]
fn generation_controls_follow_each_provider_contract() -> TestResult {
    use serde_json::json;
    use weaver_llm::{ResponseFormat, Tool, ToolChoice};

    let schema = json!({
        "type": "object",
        "properties": {"marker": {"type": "string"}},
        "required": ["marker"],
        "additionalProperties": false,
    });
    let tool = Tool {
        name: "read_marker".into(),
        description: "Return a marker".into(),
        parameters: json!({"type":"object", "properties":{}}),
    };
    let messages = messages();
    for (protocol, choice, required, format_pointer, format) in [
        (
            Protocol::OpenAi,
            json!({"type":"function","function":{"name":"read_marker"}}),
            json!("required"),
            "/response_format",
            json!({"type":"json_schema","json_schema":{"name":"marker","strict":true,"schema":schema}}),
        ),
        (
            Protocol::OpenAiResponses,
            json!({"type":"function","name":"read_marker"}),
            json!("required"),
            "/text/format",
            json!({"type":"json_schema","name":"marker","strict":true,"schema":schema}),
        ),
        (
            Protocol::Anthropic,
            json!({"type":"tool","name":"read_marker"}),
            json!({"type":"any"}),
            "/output_config/format",
            json!({"type":"json_schema","schema":schema}),
        ),
    ] {
        let encode = |options: &Options, stream| -> TestResult<Value> {
            Ok(serde_json::from_slice(
                &Request {
                    model: "fixture-model",
                    messages: &messages,
                    options,
                }
                .encode(protocol, stream)?,
            )?)
        };
        let mut options = Options {
            tools: vec![tool.clone()],
            tool_choice: Some(ToolChoice::Function("read_marker".into())),
            response_format: Some(ResponseFormat::JsonSchema {
                name: "marker".into(),
                schema: schema.clone(),
            }),
            ..Options::default()
        };
        for stream in [false, true] {
            let request = encode(&options, stream)?;
            assert_eq!(request["stream"], stream);
            assert_eq!(request["tool_choice"], choice);
            assert_eq!(request.pointer(format_pointer), Some(&format));
        }
        options.tool_choice = Some(ToolChoice::Required);
        assert_eq!(encode(&options, true)?["tool_choice"], required);

        for (selection, name) in [(ToolChoice::Auto, "auto"), (ToolChoice::None, "none")] {
            options.tool_choice = Some(selection);
            let expected = if protocol == Protocol::Anthropic {
                json!({"type": name})
            } else {
                json!(name)
            };
            assert_eq!(encode(&options, false)?["tool_choice"], expected);
        }

        options.tool_choice = Some(ToolChoice::Function("unknown".into()));
        assert!(encode(&options, true).is_err());
        options.tool_choice = Some(ToolChoice::Required);
        options.tools.clear();
        assert!(encode(&options, true).is_err());
        options.tool_choice = None;
        options.response_format = Some(ResponseFormat::JsonObject);
        if protocol == Protocol::Anthropic {
            assert!(encode(&options, true).is_err());
        } else {
            assert_eq!(
                encode(&options, true)?.pointer(format_pointer),
                Some(&json!({"type":"json_object"}))
            );
        }
        let default = encode(&Options::default(), false)?;
        assert!(default.get("tool_choice").is_none());
        assert!(default.pointer(format_pointer).is_none());
    }
    Ok(())
}
