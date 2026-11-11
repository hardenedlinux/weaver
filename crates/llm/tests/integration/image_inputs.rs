// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{TestResult, messages};
use serde_json::{Value, json};
use weaver_llm::{Error, ImageInput, ImageMediaType, Options, Protocol, Request, Role};

#[test]
fn image_blocks_preserve_order_in_each_provider_request() -> TestResult {
    let mut history = messages();
    let image_url = "https://example.invalid/screenshot.png";
    history[1].images = vec![
        ImageInput::Url {
            url: image_url.into(),
        },
        ImageInput::Inline {
            media_type: ImageMediaType::Png,
            bytes: vec![1, 2, 3],
        },
    ];
    let options = Options::default();
    let request = Request {
        model: "fixture",
        messages: &history,
        options: &options,
    };
    let inline_url = "data:image/png;base64,AQID";
    for (protocol, pointer, content) in [
        (
            Protocol::OpenAi,
            "/messages/1/content",
            json!([
                {"type":"text","text":"Hello"},
                {"type":"image_url","image_url":{"url":image_url}},
                {"type":"image_url","image_url":{"url":inline_url}}
            ]),
        ),
        (
            Protocol::OpenAiResponses,
            "/input/1/content",
            json!([
                {"type":"input_text","text":"Hello"},
                {"type":"input_image","image_url":image_url,"detail":"auto"},
                {"type":"input_image","image_url":inline_url,"detail":"auto"}
            ]),
        ),
        (
            Protocol::Anthropic,
            "/messages/0/content",
            json!([
                {"type":"text","text":"Hello"},
                {"type":"image","source":{"type":"url","url":image_url}},
                {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AQID"}}
            ]),
        ),
    ] {
        for stream in [false, true] {
            let encoded: Value = serde_json::from_slice(&request.encode(protocol, stream)?)?;
            assert_eq!(encoded.pointer(pointer), Some(&content));
        }
    }
    Ok(())
}

#[test]
fn image_inputs_reject_non_user_roles_and_invalid_sources() {
    let mut history = messages();
    let options = Options::default();
    let encode = |history: &[weaver_llm::Message]| {
        Request {
            model: "fixture",
            messages: history,
            options: &options,
        }
        .encode(Protocol::OpenAiResponses, true)
    };
    for image in [
        ImageInput::Url {
            url: "file:///tmp/screenshot.png".into(),
        },
        ImageInput::Url {
            url: "https://user:secret@example.invalid/screenshot.png".into(),
        },
        ImageInput::Inline {
            media_type: ImageMediaType::Png,
            bytes: vec![],
        },
    ] {
        history[1].images = vec![image];
        assert!(matches!(encode(&history), Err(Error::Request(_))));
    }
    history[1].role = Role::Assistant;
    history[1].images = vec![ImageInput::Inline {
        media_type: ImageMediaType::Png,
        bytes: vec![1],
    }];
    assert!(matches!(encode(&history), Err(Error::Request(_))));
}
