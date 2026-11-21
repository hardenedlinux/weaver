// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Independent standard wire fixtures, not output from the encoder under test.
use serde_json::{Value, json};
use weaver_llm::{Protocol, ToolCall};

#[derive(Clone, Copy, Debug)]
pub enum Case {
    Chat,
    Responses,
    Messages,
}
impl Case {
    pub fn protocol(self) -> &'static str {
        match self {
            Self::Chat => weaver_contracts::CHAT_TURN_SSE,
            Self::Responses => weaver_contracts::RESPONSES_TURN_SSE,
            Self::Messages => weaver_contracts::ANTHROPIC_TURN_SSE,
        }
    }
    pub fn decoder(self) -> Protocol {
        match self {
            Self::Chat => Protocol::OpenAi,
            Self::Responses => Protocol::OpenAiResponses,
            Self::Messages => Protocol::Anthropic,
        }
    }
    pub fn path(self) -> &'static str {
        match self {
            Self::Chat => "/v1/chat/completions",
            Self::Responses => "/v1/responses",
            Self::Messages => "/v1/messages",
        }
    }
    fn request(self) -> Value {
        let schema = json!({"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false});
        match self {
            Self::Chat => {
                json!({"model":"model-a","stream":true,"max_tokens":32,"messages":[{"role":"user","content":"read"}],"tools":[{"type":"function","function":{"name":"read","parameters":schema}}]})
            }
            Self::Responses => {
                json!({"model":"model-a","stream":true,"store":false,"max_output_tokens":32,"include":["reasoning.encrypted_content"],"input":[{"role":"user","content":"read"}],"tools":[{"type":"function","name":"read","parameters":schema}]})
            }
            Self::Messages => {
                json!({"model":"model-a","stream":true,"max_tokens":2048,"thinking":{"type":"enabled","budget_tokens":1024},"messages":[{"role":"user","content":"read"}],"tools":[{"name":"read","input_schema":schema}]})
            }
        }
    }
    pub fn first_request(self) -> String {
        self.request().to_string()
    }
    pub fn followup(self, calls: &[ToolCall], opaque: Option<Value>) -> String {
        assert_eq!(calls.len(), 1);
        let call = &calls[0];
        let mut request = self.request();
        match self {
            Self::Chat => {
                request["messages"].as_array_mut().expect("messages").extend([
                    json!({"role":"assistant","content":null,"tool_calls":[{"id":call.id,"type":"function","function":{"name":call.name,"arguments":call.arguments.to_string()}}]}),
                    json!({"role":"tool","tool_call_id":call.id,"content":"file-result"}),
                ]);
            }
            Self::Responses => {
                let items = request["input"].as_array_mut().expect("input");
                items.extend(
                    opaque
                        .expect("Responses continuation")
                        .as_array()
                        .expect("items")
                        .iter()
                        .cloned(),
                );
                items.push(
                    json!({"type":"function_call_output","call_id":call.id,"output":"file-result"}),
                );
            }
            Self::Messages => {
                request["messages"].as_array_mut().expect("messages").extend([
                    json!({"role":"assistant","content":opaque.expect("Messages continuation")}),
                    json!({"role":"user","content":[{"type":"tool_result","tool_use_id":call.id,"content":"file-result"}]}),
                ]);
            }
        }
        request.to_string()
    }
    pub fn tool_reply(self) -> String {
        match self {
            Self::Chat => include_str!("../fixtures/http-turns/chat-tools.sse"),
            Self::Responses => include_str!("../fixtures/http-turns/responses-tools.sse"),
            Self::Messages => include_str!("../fixtures/http-turns/messages-tools.sse"),
        }
        .into()
    }
    pub fn text_reply(self) -> String {
        match self {
            Self::Chat => super::fixture::text_reply(),
            Self::Responses => include_str!("../fixtures/http-turns/responses-text.sse").into(),
            Self::Messages => include_str!("../fixtures/http-turns/messages-text.sse").into(),
        }
    }
}
