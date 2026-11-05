// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

proptest::proptest! {
    #[test]
    fn cumulative_usage_is_replaced(
        input in 0u64..4096, read in 0u64..4096, write in 0u64..4096,
        initial in 0u64..2048, extra in 0u64..2048,
    ) {
        let mut decoder = super::Decoder::new(&b""[..], "bound");
        let stop = serde_json::json!({"type":"message_stop"});
        let start = serde_json::json!({"type":"message_start","message":{
            "model":"bound","role":"assistant","content":[],
            "usage":{"input_tokens":input,"cache_read_input_tokens":read,
                "cache_creation_input_tokens":write,"output_tokens":initial}
        }});
        let mut changed = start.clone();
        changed["message"]["model"] = serde_json::json!("replacement");
        proptest::prop_assert!(decoder.accept(&changed).is_err());
        decoder.accept(&start).expect("bound model");
        proptest::prop_assert!(decoder.accept(&stop).is_err());
        let total = initial + extra;
        decoder.accept(&serde_json::json!({"type":"message_delta","delta":{},"usage":{"output_tokens":initial}})).expect("first counter");
        decoder.accept(&serde_json::json!({"type":"message_delta","delta":{"stop_reason":"end_turn"},
            "usage":{"output_tokens":total}})).expect("final counter");
        proptest::prop_assert_eq!(decoder.tokens(),[input,read,write,total]);
        proptest::prop_assert!(decoder.accept(&stop).is_ok());
        proptest::prop_assert!(decoder.accept(&stop).is_err());
    }
}
