// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::Decoder;
use std::{
    io::Cursor,
    pin::Pin,
    sync::LazyLock,
    task::{Context, Poll},
};
use tokio::io::{AsyncRead, ReadBuf};
use weaver_contracts::ProviderEventKind;
struct Fragmented {
    input: Cursor<Vec<u8>>,
    chunk: usize,
}
impl AsyncRead for Fragmented {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        output: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        let limit = self.chunk.min(output.remaining());
        let mut fragment = ReadBuf::new(output.initialize_unfilled_to(limit));
        std::task::ready!(Pin::new(&mut self.input).poll_read(cx, &mut fragment))?;
        let count = fragment.filled().len();
        output.advance(count);
        Poll::Ready(Ok(()))
    }
}
static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .build()
        .expect("Tokio test runtime")
});
fn stream(text: &str) -> Vec<u8> {
    let chunk = serde_json::json!({"id":"s","object":"chat.completion.chunk","model":"model-a","choices":[{"index":0,"delta":{"content":text},"finish_reason":null}]});
    let finish = serde_json::json!({"id":"s","object":"chat.completion.chunk","model":"model-a","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]});
    format!("retry: 0\r\nid: reconnect-must-not-retry\r\ndata: {chunk}\r\n\r\ndata: {finish}\n\ndata: [DONE]\n\n").into_bytes()
}
proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(64))]
    #[test]
    fn arbitrary_network_fragmentation_preserves_sse_identity(chunk in 1usize..64,text in "[a-z界é]{0,32}") {
        let mut decoder=Decoder::new(Fragmented{input:Cursor::new(stream(&text)),chunk},"model-a");
        let event=RUNTIME.block_on(decoder.next()).expect("delta");proptest::prop_assert_eq!(event.text,text);
        proptest::prop_assert_eq!(RUNTIME.block_on(decoder.next()).expect("finish").kind,ProviderEventKind::Finish);
        proptest::prop_assert_eq!(RUNTIME.block_on(decoder.next()).expect("done").kind,ProviderEventKind::Done);
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn truncated_oversized_and_wrong_model_streams_are_not_completed() {
    assert!(
        Decoder::new(Cursor::new(b"data: [DONE]\n\n"), "model-a")
            .next()
            .await
            .is_err()
    );
    assert!(
        Decoder::new(Cursor::new(vec![b'x'; 65537]), "model-a")
            .next()
            .await
            .is_err()
    );
    let mut wrong = Decoder::new(Cursor::new(stream("hello")), "different-model");
    assert!(wrong.next().await.is_err());
    let bytes = stream("prefix");
    let end = bytes.iter().position(|b| *b == b'\n').expect("newline");
    assert!(
        Decoder::new(Cursor::new(bytes[..end].to_vec()), "model-a")
            .next()
            .await
            .is_err()
    );
}

proptest::proptest! {
    #[test]
    fn inclusive_provider_usage_conserves_tokens(
        uncached in 0u64..10000, cached in 0u64..10000, output in 0u64..10000,
    ) {
        let prompt = uncached + cached;
        let mut value = serde_json::json!({
            "prompt_tokens": prompt, "completion_tokens": output,
            "prompt_tokens_details": {"cached_tokens": cached},
        });
        let result = super::normalize_usage(&value, prompt + output).expect("valid usage");
        proptest::prop_assert_eq!(result, Some([uncached, cached, 0, output]));
        proptest::prop_assert!(super::normalize_usage(&value, prompt + output + 1).is_err());
        value["prompt_tokens_details"]["cached_tokens"] = serde_json::json!(prompt + 1);
        proptest::prop_assert!(super::normalize_usage(&value, prompt + output).is_err());
    }
}
