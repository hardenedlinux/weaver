// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! User-supplied image inputs and provider content blocks.

use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{Error, Protocol};

/// Image media types shared by the supported provider protocols.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ImageMediaType {
    /// PNG image.
    Png,
    /// JPEG image.
    Jpeg,
    /// WebP image.
    Webp,
    /// GIF image.
    Gif,
}

impl ImageMediaType {
    fn mime(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
            Self::Webp => "image/webp",
            Self::Gif => "image/gif",
        }
    }
}

/// An image sent in a user message.
#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "source", rename_all = "snake_case")]
pub enum ImageInput {
    /// HTTPS URL for the provider to fetch.
    Url {
        /// Absolute HTTPS image URL.
        url: String,
    },
    /// Bytes supplied by the caller and encoded inline.
    Inline {
        /// MIME family of the supplied image.
        media_type: ImageMediaType,
        /// Encoded image file bytes, before Base64 transport encoding.
        bytes: Vec<u8>,
    },
}

impl std::fmt::Debug for ImageInput {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Url { .. } => formatter.debug_struct("Url").finish_non_exhaustive(),
            Self::Inline { media_type, bytes } => formatter
                .debug_struct("Inline")
                .field("media_type", media_type)
                .field("byte_count", &bytes.len())
                .finish(),
        }
    }
}

impl ImageInput {
    pub(crate) fn validate(&self) -> Result<(), Error> {
        match self {
            Self::Url { url }
                if reqwest::Url::parse(url).is_ok_and(|parsed| {
                    parsed.scheme() == "https"
                        && parsed.has_host()
                        && parsed.username().is_empty()
                        && parsed.password().is_none()
                        && parsed.fragment().is_none()
                }) =>
            {
                Ok(())
            }
            Self::Inline { bytes, .. } if !bytes.is_empty() => Ok(()),
            _ => Err(Error::Request("invalid image URL or empty inline image")),
        }
    }

    fn wire_block(&self, protocol: Protocol) -> Value {
        if protocol == Protocol::Anthropic {
            let source = match self {
                Self::Url { url } => json!({"type":"url","url":url}),
                Self::Inline { media_type, bytes } => json!({
                    "type":"base64","media_type":media_type.mime(),"data":STANDARD.encode(bytes),
                }),
            };
            return json!({"type":"image","source":source});
        }
        let url = match self {
            Self::Url { url } => std::borrow::Cow::Borrowed(url.as_str()),
            Self::Inline { media_type, bytes } => std::borrow::Cow::Owned(format!(
                "data:{};base64,{}",
                media_type.mime(),
                STANDARD.encode(bytes)
            )),
        };
        match protocol {
            Protocol::OpenAi => json!({"type":"image_url","image_url":{"url":url}}),
            Protocol::OpenAiResponses => {
                json!({"type":"input_image","image_url":url,"detail":"auto"})
            }
            Protocol::Anthropic => unreachable!("Anthropic image sources are encoded above"),
        }
    }
}

pub(crate) fn content_blocks(text: &str, images: &[ImageInput], protocol: Protocol) -> Vec<Value> {
    let mut blocks = Vec::with_capacity(images.len() + usize::from(!text.is_empty()));
    if !text.is_empty() {
        let kind = if protocol == Protocol::OpenAiResponses {
            "input_text"
        } else {
            "text"
        };
        blocks.push(json!({"type":kind,"text":text}));
    }
    blocks.extend(images.iter().map(|image| image.wire_block(protocol)));
    blocks
}
