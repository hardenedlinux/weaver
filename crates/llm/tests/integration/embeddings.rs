// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{TestResult, upstream};
use serde_json::json;
use std::time::Duration;
use weaver_llm::{Client, EmbeddingInput, EmbeddingRequest, Endpoint, Error, Protocol};

const JSON_OK: &str =
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n";

#[tokio::test]
async fn embeddings_returns_batch_in_input_order() -> TestResult {
    let client = Client::new(Duration::from_secs(2), 4096)?;
    let body = r#"{"model":"embed","data":[{"index":1,"embedding":[3,4]},{"index":0,"embedding":[1,2]}],"usage":{"prompt_tokens":4,"total_tokens":4}}"#;
    for (input, expected) in [
        (
            EmbeddingInput::Text(&["alpha", "beta"]),
            json!(["alpha", "beta"]),
        ),
        (
            EmbeddingInput::Tokens(&[&[10, 11], &[12]]),
            json!([[10, 11], [12]]),
        ),
    ] {
        let (url, observed) = upstream(format!("{JSON_OK}{body}")).await?;
        let batch = client
            .embed(
                &Endpoint::new(Protocol::OpenAi, &url)?,
                "key",
                &EmbeddingRequest {
                    model: "embed",
                    input,
                    dimensions: Some(2),
                },
            )
            .await?;
        assert_eq!(batch.vectors, [[1.0, 2.0], [3.0, 4.0]]);
        assert_eq!(batch.usage.map(|usage| usage.total_tokens), Some(4));
        let (headers, request) = observed.await??;
        assert!(headers.contains("authorization: bearer key"));
        assert_eq!(request["input"], expected);
        assert_eq!(request["dimensions"], 2);
        assert_eq!(request["encoding_format"], "float");
    }
    Ok(())
}

#[tokio::test]
async fn embeddings_rejects_invalid_index_or_dimensions() -> TestResult {
    let client = Client::new(Duration::from_secs(2), 4096)?;
    for data in [
        json!([{"index":0,"embedding":[1,2]},{"index":0,"embedding":[3,4]}]),
        json!([{"index":0,"embedding":[1,2]},{"index":1,"embedding":[3]}]),
    ] {
        let body = json!({"model":"embed","data":data});
        let (url, observed) = upstream(format!("{JSON_OK}{body}")).await?;
        let result = client
            .embed(
                &Endpoint::new(Protocol::OpenAi, &url)?,
                "key",
                &EmbeddingRequest {
                    model: "embed",
                    input: EmbeddingInput::Text(&["alpha", "beta"]),
                    dimensions: Some(2),
                },
            )
            .await;
        assert!(matches!(result, Err(Error::Response)));
        observed.await??;
    }
    Ok(())
}
