// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
use crate::ProviderSseEncoder;
use weaver_contracts::{
    CHAT_TURN_SSE, ProviderEvent, ProviderEventKind, ProviderRoute, ProviderTurnControl,
    ProviderTurnEvent, ProviderTurnIdentity, ProviderTurnMetadata, ProviderTurnPayload,
};
fn route() -> ProviderRoute {
    ProviderRoute {
        target: "primary".into(),
        endpoint: "https://provider.invalid/v1/chat/completions".into(),
    }
}
fn start() -> ProviderEvent {
    ProviderEvent {
        sequence: 0,
        text: String::new(),
        tokens: 0,
        kind: ProviderEventKind::Turn(Box::new(ProviderTurnEvent {
            version: 1,
            metadata: Some(ProviderTurnMetadata {
                identity: Some(ProviderTurnIdentity {
                    id: "r".into(),
                    model: "fixture".into(),
                }),
                usage: None,
                position: None,
                control: Some(ProviderTurnControl::Started),
            }),
            payload: ProviderTurnPayload::Control,
        })),
    }
}
#[test]
fn source_route_model_sequence_and_legacy_substitutions_close_the_response() {
    for fault in 0..6 {
        let mut projection = ProviderSseEncoder::new(CHAT_TURN_SSE, "fixture", 65536, 123)
            .expect("typed SSE projection fixture");
        projection
            .prepare(&route(), "fixture", &[start()])
            .expect("typed SSE projection fixture");
        let mut selected = route();
        let mut model = "fixture";
        let mut event = start();
        event.sequence = 1;
        match fault {
            0 => selected.target = "foreign".into(),
            1 => selected.endpoint = "https://other.invalid/v1/chat/completions".into(),
            2 => model = "other",
            3 => event.sequence = 0,
            4 => event.tokens = 1,
            5 => event.kind = ProviderEventKind::Delta,
            _ => unreachable!(),
        }
        assert!(projection.prepare(&selected, model, &[event]).is_err());
        assert!(projection.prepare(&route(), "fixture", &[start()]).is_err());
    }
}
#[test]
fn invalid_later_row_returns_no_partial_batch_and_prevents_replay() {
    let mut projection = ProviderSseEncoder::new(CHAT_TURN_SSE, "fixture", 65536, 123)
        .expect("typed SSE projection fixture");
    let mut wrong = start();
    wrong.sequence = 9;
    assert!(
        projection
            .prepare(&route(), "fixture", &[start(), wrong])
            .is_err()
    );
    assert!(projection.prepare(&route(), "fixture", &[start()]).is_err());
}
#[test]
fn a_provider_identity_cannot_expand_the_source_selected_model() {
    let mut projection = ProviderSseEncoder::new(CHAT_TURN_SSE, "fixture", 65536, 123)
        .expect("typed SSE projection fixture");
    let mut event = start();
    let ProviderEventKind::Turn(turn) = &mut event.kind else {
        unreachable!()
    };
    turn.metadata
        .as_mut()
        .expect("typed SSE projection fixture")
        .identity
        .as_mut()
        .expect("typed SSE projection fixture")
        .model = "other".into();
    assert!(projection.prepare(&route(), "fixture", &[event]).is_err());
    assert!(projection.prepare(&route(), "fixture", &[start()]).is_err());
}
