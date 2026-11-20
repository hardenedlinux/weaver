// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Actual committed native receipts; an encoded buffer is not delivery authority.
use tokio_stream::StreamExt;
use weaver_broker::ProviderOutput;
use weaver_contracts::{
    ProviderEvent, ProviderEventKind, ProviderTurnEvent, ProviderTurnIdentity,
    ProviderTurnMetadata, ProviderTurnPayload,
};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sse_receiver_rechecks_current_receipt_after_queueing_before_body_transfer() {
    for fault in 0..3 {
        let directory = tempfile::tempdir().expect("store");
        let path = directory.path().join("delivery.db");
        let (ready, receive) = tokio::sync::oneshot::channel();
        let (done, finish) = tokio::sync::oneshot::channel();
        let (drained, joined) = tokio::sync::oneshot::channel();
        let worker = tokio::task::spawn_blocking(move || {
            let (mut ledger, permit) = super::backpressure_tests::prepared_protocol_ledger(
                &path,
                Some(weaver_contracts::CHAT_TURN_SSE),
            );
            let (mut output, mut receiver, _sender) = super::backpressure_tests::full_output();
            receiver
                .try_recv()
                .expect("capacity fixture")
                .expect_err("inert fixture");
            receiver
                .try_recv()
                .expect("capacity fixture")
                .expect_err("inert fixture");
            output.projection = Some(
                weaver_broker::ProviderSseEncoder::new(
                    weaver_contracts::CHAT_TURN_SSE,
                    "model-a",
                    65_536,
                    1,
                )
                .expect("projection"),
            );
            let identity = ProviderTurnIdentity {
                id: "response-a".into(),
                model: "model-a".into(),
            };
            let event = ProviderEvent {
                sequence: 0,
                text: String::new(),
                tokens: 0,
                kind: ProviderEventKind::Turn(Box::new(ProviderTurnEvent {
                    version: 1,
                    metadata: Some(ProviderTurnMetadata {
                        identity: Some(identity),
                        usage: None,
                        position: None,
                        control: Some(weaver_contracts::ProviderTurnControl::Started),
                    }),
                    payload: ProviderTurnPayload::Text {
                        text: "guarded".into(),
                    },
                })),
            };
            let slot = output.reserve().expect("real queue credit");
            let release = ledger
                .prepare_provider_release(&permit, "sse-packet", "sse", 1)
                .expect("burn interval");
            let prepared = output
                .prepare(permit.route(), &permit.plan().model, &[event], "sse")
                .expect("inert SSE preparation");
            ledger
                .release_provider_for_delivery(&permit, release, "sse", |_, receipt| {
                    output.emit(slot, prepared, receipt)
                })
                .expect("deciding guard and enqueue");
            output
                .finish_delivery(&mut ledger, &permit, "sse")
                .expect("acknowledge native receipt");
            if fault == 1 {
                ledger
                    .publish_typed(
                        Some(0),
                        "forbid(principal,action,resource);",
                        include_str!("../../../../prod/policies/provider/schema.json"),
                        2,
                    )
                    .expect("replace authority after enqueue");
            }
            if fault == 2 {
                output.cancelled.cancel();
            }
            let cursor =
                weaver_ledger::DeliveryCursor::new(permit.plan()).expect("one deciding receiver");
            ready
                .send((
                    receiver,
                    cursor,
                    output.cancelled.clone(),
                    output.shutdown.clone(),
                ))
                .unwrap_or_else(|_| panic!("receiver handoff"));
            let result = output.drain_delivery(&mut ledger, &permit, "sse");
            drained.send(result.is_ok()).expect("producer result");
            // A failed producer owns no later handoff; dropping the same output
            // releases its receipt custody and wakes the deciding receiver.
            let reactor = output.runtime.clone();
            drop(output);
            reactor.block_on(async {
                tokio::time::timeout(std::time::Duration::from_secs(3), finish)
                    .await
                    .expect("consumer bound")
                    .expect("consumer finished")
            });
            assert_eq!(ledger.held("f").expect("original hold"), 4);
            ledger.close().expect("native ledger exit");
        });
        let (receiver, cursor, cancelled, shutdown) = receive.await.expect("prepared and queued");
        let response = crate::grpc_delivery::ResponseStream::new(
            receiver,
            cursor,
            cancelled,
            shutdown.cancelled_owned(),
        );
        let mut stream = crate::http_delivery::SseStream(response);
        let observed = tokio::time::timeout(std::time::Duration::from_secs(3), stream.next())
            .await
            .expect("body poll bound");
        match fault {
            0 => {
                let bytes = observed.expect("one frame").expect("current receipt");
                assert!(
                    std::str::from_utf8(&bytes)
                        .expect("SSE")
                        .contains("guarded")
                );
            }
            1 => {
                assert_eq!(
                    observed
                        .expect("native rejection")
                        .expect_err("old receipt cannot transfer bytes")
                        .code(),
                    tonic::Code::FailedPrecondition
                );
            }
            _ => assert!(
                observed.is_none(),
                "cancelled body cannot synthesize success"
            ),
        }
        assert_eq!(
            tokio::time::timeout(std::time::Duration::from_secs(3), joined)
                .await
                .expect("producer bound")
                .expect("producer acknowledgment"),
            fault == 0
        );
        drop(stream);
        done.send(()).expect("consumer joined");
        worker.await.expect("native owner joined");
    }
}
