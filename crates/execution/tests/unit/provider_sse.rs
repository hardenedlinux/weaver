// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::Decoder;
use std::io::{Cursor, Read};
use weaver_contracts::ProviderEventKind;
struct Fragmented {
    input: Cursor<Vec<u8>>,
    chunk: usize,
}
impl Read for Fragmented {
    fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
        let count = output.len().min(self.chunk);
        self.input.read(&mut output[..count])
    }
}
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
        let event=decoder.next().expect("delta");proptest::prop_assert_eq!(event.text,text);
        proptest::prop_assert_eq!(decoder.next().expect("finish").kind,ProviderEventKind::Finish);
        proptest::prop_assert_eq!(decoder.next().expect("done").kind,ProviderEventKind::Done);
    }
}
#[test]
fn truncated_oversized_and_wrong_model_streams_are_not_completed() {
    assert!(
        Decoder::new(Cursor::new(b"data: [DONE]\n\n"), "model-a")
            .next()
            .is_err()
    );
    assert!(
        Decoder::new(Cursor::new(vec![b'x'; 65537]), "model-a")
            .next()
            .is_err()
    );
    let mut wrong = Decoder::new(Cursor::new(stream("hello")), "different-model");
    assert!(wrong.next().is_err());
    let bytes = stream("prefix");
    let end = bytes.iter().position(|b| *b == b'\n').expect("newline");
    assert!(
        Decoder::new(Cursor::new(bytes[..end].to_vec()), "model-a")
            .next()
            .is_err()
    );
}
