// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Independent receipt-before-response crash cut on the original HTTP runtime.
use super::{Case, UNANSWERED, at_cut, child, fixture, kill};
use std::{sync::Arc, time::Duration};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn three_protocols_keep_unanswered_dispatch_after_process_kill() {
    for (case, name) in [
        (Case::Chat, "chat"),
        (Case::Responses, "responses"),
        (Case::Messages, "messages"),
    ] {
        let directory = tempfile::tempdir().expect("durable test store");
        let gate = Arc::new(tokio::sync::Notify::new());
        let mut peer =
            fixture::provider_with_response_gate(vec![case.tool_reply()], Some(gate.clone())).await;
        let endpoint = peer.endpoint.replace("/v1/chat/completions", case.path());
        tokio::fs::write(directory.path().join("root.pem"), &peer.root)
            .await
            .expect("root");
        let mut owner = child(directory.path(), &endpoint, name, "send")
            .stdout(std::process::Stdio::piped())
            .spawn()
            .expect("first process");
        at_cut(&mut owner, UNANSWERED).await;
        let actual = tokio::time::timeout(Duration::from_secs(8), peer.requests.recv())
            .await
            .expect("bounded actual request receipt")
            .expect("upstream request");
        assert_eq!(actual, case.first_request());
        // The TLS peer has read the exact request, but its response gate is
        // still closed. A local write/callback marker cannot stand in for this.
        kill(&mut owner).await;
        gate.notify_one();
        let resumed = tokio::time::timeout(
            Duration::from_secs(8),
            child(directory.path(), &endpoint, name, "recover-unknown").output(),
        )
        .await
        .expect("recovered child deadline")
        .expect("recovered process");
        assert!(
            resumed.status.success(),
            "{case:?}: {}\n{}",
            String::from_utf8_lossy(&resumed.stdout),
            String::from_utf8_lossy(&resumed.stderr)
        );
        let result = peer
            .finish()
            .await
            .expect("no extra connection or observer panic");
        if let Err(error) = result {
            assert!(
                matches!(
                    error.kind(),
                    std::io::ErrorKind::BrokenPipe
                        | std::io::ErrorKind::ConnectionReset
                        | std::io::ErrorKind::ConnectionAborted
                        | std::io::ErrorKind::UnexpectedEof
                ),
                "unexpected fixture error: {error}"
            );
        }
        let store = weaver_ledger::persistence::Session::open(directory.path().join("ledger.db"))
            .expect("retained state");
        let (state, dispatched, reserved, next): (String, i64, i64, i64) =
            weaver_ledger::persistence::one(
                &store,
                "SELECT state,dispatched,reserved,next_event FROM provider_runs",
                (),
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .expect("original dispatch");
        assert_eq!(state, "unknown");
        // A guarded callback may have returned just before SIGKILL. Neither
        // callback transaction completion nor remote outcome is inferred here.
        assert!([1, 2].contains(&dispatched));
        assert_eq!((reserved, next), (4, 0));
        let counts: (i64,i64,i64,i64,i64) = weaver_ledger::persistence::one(&store,
            "SELECT (SELECT COUNT(*) FROM provider_runs), (SELECT COUNT(*) FROM provider_session_turns), (SELECT COUNT(*) FROM provider_releases), (SELECT COUNT(*) FROM provider_terminal_usage), (SELECT SUM(held) FROM budget_domains WHERE id=root)", (),
            |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).expect("durable original and reservation");
        assert_eq!(
            counts,
            (1, 1, 0, 0, 4),
            "{case:?}: no resend, terminal, new original or refund after uncertain I/O"
        );
        store.close().expect("SQL owner close");
    }
}
