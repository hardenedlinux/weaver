// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::TokenCategories;
use crate::{Protocol, TurnDecoder};

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(128))]
    #[test]
    fn inclusive_openai_input_is_partitioned_without_double_counting(
        ordinary in 0u64..4096, read in 0u64..4096, write in 0u64..4096, output in 0u64..4096,
    ) {
        let input = ordinary + read + write;
        for chat in [false, true] {
            let mut value = serde_json::json!({"total_tokens": input + output});
            value[if chat {"prompt_tokens"} else {"input_tokens"}] = input.into();
            value[if chat {"completion_tokens"} else {"output_tokens"}] = output.into();
            value[if chat {"prompt_tokens_details"} else {"input_tokens_details"}] = serde_json::json!({"cached_tokens":read, "cache_write_tokens":write});
            let actual = TokenCategories::openai(&value, chat).expect("token category fixture");
            proptest::prop_assert_eq!(actual, TokenCategories { ordinary_input:ordinary, cache_read_input:read, cache_write_input:write, output });
        }
    }
}

#[test]
fn cumulative_anthropic_updates_replace_and_nulls_preserve_categories() {
    let first = TokenCategories::anthropic_start(&serde_json::json!({"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":0})).expect("token category fixture");
    let delta =
        serde_json::json!({"input_tokens":12,"cache_read_input_tokens":null,"output_tokens":3});
    let once = first
        .anthropic_delta(&delta)
        .expect("token category fixture");
    assert_eq!(
        once.anthropic_delta(&delta)
            .expect("token category fixture"),
        once
    );
    assert_eq!(
        once,
        TokenCategories {
            ordinary_input: 12,
            cache_read_input: 20,
            cache_write_input: 30,
            output: 3
        }
    );
}

#[test]
fn inconsistent_or_invalid_counts_cannot_become_terminal_usage() {
    for usage in [
        serde_json::json!({"input_tokens":10,"output_tokens":2,"total_tokens":11}),
        serde_json::json!({"input_tokens":10,"output_tokens":2,"input_tokens_details":{"cached_tokens":8,"cache_write_tokens":3}}),
        serde_json::json!({"input_tokens":10,"output_tokens":2,"input_tokens_details":{"cached_tokens":-1}}),
        serde_json::json!({"input_tokens":u64::MAX,"output_tokens":1}),
    ] {
        assert!(TokenCategories::openai(&usage, false).is_err());
    }
    assert!(TokenCategories::anthropic_start(&serde_json::json!({"input_tokens":u64::MAX,"cache_read_input_tokens":1,"output_tokens":0})).is_err());
}

#[test]
fn usage_is_hidden_until_a_validated_terminal_and_missing_usage_stays_unknown() {
    let event = serde_json::json!({"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12,"prompt_tokens_details":{"cached_tokens":3,"cache_write_tokens":2}}});
    let mut codec = TurnDecoder::new(Protocol::OpenAi, 4096);
    codec
        .push_bytes(format!("data: {event}\n\n").as_bytes())
        .expect("token category fixture");
    assert!(
        codec
            .next_event()
            .expect("token category fixture")
            .is_none()
    );
    assert!(codec.terminal_usage().is_none());
    assert!(codec.finish().is_err());
    assert!(codec.terminal_usage().is_none());

    let mut codec = TurnDecoder::new(Protocol::OpenAi, 4096);
    codec.push_bytes(b"data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n").expect("token category fixture");
    assert!(
        codec
            .next_event()
            .expect("token category fixture")
            .is_some()
    );
    assert!(codec.terminal_usage().is_none());
}
