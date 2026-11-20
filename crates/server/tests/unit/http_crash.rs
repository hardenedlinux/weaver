// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! OS-process recovery at completed and unanswered HTTP turns, not a Scheme test.
use super::{Harness, completed, fixture, protocol::Case};
use std::{os::unix::process::ExitStatusExt, path::Path, time::Duration};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const CHILD: &str = "grpc::service::http_tests::turns::crash::http_recovery_child";
const READY: &str = "WEAVER_HTTP_TOOL_COMMITTED";
const UNANSWERED: &str = "WEAVER_HTTP_REQUEST_WAITING";
#[path = "http_unanswered.rs"]
mod unanswered;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn http_recovery_child() {
    let Ok(phase) = std::env::var("WEAVER_HTTP_RECOVERY_PHASE") else {
        return;
    };
    let case = match std::env::var("WEAVER_HTTP_RECOVERY_CASE")
        .expect("case")
        .as_str()
    {
        "chat" => Case::Chat,
        "responses" => Case::Responses,
        "messages" => Case::Messages,
        _ => panic!("frozen protocol"),
    };
    let directory = std::env::var("WEAVER_HTTP_RECOVERY_DIR").expect("directory");
    let directory = Path::new(&directory);
    let root = tokio::fs::read_to_string(directory.join("root.pem"))
        .await
        .expect("root");
    let endpoint = std::env::var("WEAVER_HTTP_RECOVERY_ENDPOINT").expect("endpoint");
    let initial = phase == "prime" || phase == "send";
    assert!(initial || phase == "resume" || phase == "recover-unknown");
    let owner = Harness::start(
        &directory.join("ledger.db"),
        &root,
        initial.then_some((endpoint.as_str(), case.protocol())),
    )
    .await;
    let first_body = case.first_request();
    if phase == "send" {
        let response = owner
            .submit(case, "tool-turn", &first_body)
            .await
            .expect("HTTP headers");
        assert_eq!(response.status(), 200);
        let body = response.bytes();
        tokio::pin!(body);
        std::future::poll_fn(|cx| {
            use std::{future::Future, task::Poll};
            assert!(
                body.as_mut().poll(cx).is_pending(),
                "unanswered turn cannot already be complete"
            );
            Poll::Ready(())
        })
        .await;
        let mut stdout = tokio::io::stdout();
        stdout
            .write_all(format!("\n{UNANSWERED}\n").as_bytes())
            .await
            .expect("pending cut");
        stdout.flush().await.expect("parent observation");
        // The parent independently sees the exact provider request while its
        // TLS peer withholds every response byte, then kills this owner.
        std::future::pending::<()>().await;
    } else if phase == "recover-unknown" {
        for _ in 0..2 {
            if let Ok(retry) = owner.submit(case, "tool-turn", &first_body).await {
                assert!(
                    retry.bytes().await.is_err(),
                    "unknown original cannot be replayed"
                );
            }
        }
        assert_eq!(
            owner.derivations.load(std::sync::atomic::Ordering::SeqCst),
            0,
            "recovery reuses the existing exact decision without a new advisory call"
        );
        let changed = format!("{first_body} ");
        assert_eq!(
            owner
                .submit(case, "tool-turn", &changed)
                .await
                .expect("changed retry")
                .status(),
            409
        );
        fixture::change(&owner.source, false).await;
        assert_eq!(
            owner
                .submit(case, "after-withdrawal", &first_body)
                .await
                .expect("withdrawal")
                .status(),
            409
        );
    } else if initial {
        let first = completed(
            owner
                .submit(case, "tool-turn", &first_body)
                .await
                .expect("first headers"),
            case,
        )
        .await;
        assert_eq!(first.calls.len(), 1);
        assert_eq!(first.calls[0].id, "call-1");
        assert_eq!(first.calls[0].name, "read");
        assert_eq!(first.calls[0].arguments, serde_json::json!({"path":"file"}));
        match case {
            Case::Responses => assert_eq!(
                first.opaque.as_ref().expect("items")[0]["encrypted_content"],
                "opaque-keep"
            ),
            Case::Messages => {
                let blocks = first.opaque.as_ref().expect("blocks");
                assert_eq!(blocks[0]["signature"], "sig-keep");
                assert_eq!(blocks[1]["data"], "opaque-redacted");
                assert_eq!(blocks[2]["id"], "call-1");
            }
            Case::Chat => {}
        }
        let next = case.followup(&first.calls, first.opaque);
        tokio::fs::write(directory.join("followup.json"), next)
            .await
            .expect("retained followup");
        assert_eq!(
            owner.derivations.load(std::sync::atomic::Ordering::SeqCst),
            1
        );
        let mut stdout = tokio::io::stdout();
        stdout
            .write_all(format!("\n{READY}\n").as_bytes())
            .await
            .expect("parent marker");
        stdout.flush().await.expect("visible crash cut");
        // No shutdown, drain or destructor is run. The parent kills this process.
        std::future::pending::<()>().await;
    } else {
        let body = tokio::fs::read_to_string(directory.join("followup.json"))
            .await
            .expect("retained continuation");
        let second = completed(
            owner
                .submit(case, "result-turn", &body)
                .await
                .expect("resumed headers"),
            case,
        )
        .await;
        assert_eq!(second.text, "hello");
        assert!(second.calls.is_empty());
        assert_eq!(
            owner.derivations.load(std::sync::atomic::Ordering::SeqCst),
            1
        );
        if let Ok(retry) = owner.submit(case, "tool-turn", &first_body).await {
            assert!(retry.bytes().await.is_err(), "completed turn cannot replay");
        }
        assert_eq!(
            owner.derivations.load(std::sync::atomic::Ordering::SeqCst),
            1
        );
        assert!(
            owner
                .submit(case, "over-budget", &body)
                .await
                .expect("budget headers")
                .bytes()
                .await
                .is_err()
        );
        fixture::change(&owner.source, false).await;
        assert_eq!(
            owner
                .submit(case, "withdrawn", &body)
                .await
                .expect("withdrawal")
                .status(),
            409
        );
    }
    owner.finish().await;
}

fn child(directory: &Path, endpoint: &str, case: &str, phase: &str) -> tokio::process::Command {
    let mut command =
        tokio::process::Command::new(std::env::current_exe().expect("test executable"));
    command
        .args(["--exact", CHILD, "--nocapture", "--test-threads=4"])
        .env("WEAVER_HTTP_RECOVERY_PHASE", phase)
        .env("WEAVER_HTTP_RECOVERY_CASE", case)
        .env("WEAVER_HTTP_RECOVERY_DIR", directory)
        .env("WEAVER_HTTP_RECOVERY_ENDPOINT", endpoint)
        .kill_on_drop(true);
    command
}

async fn at_cut(child: &mut tokio::process::Child, marker: &str) {
    let mut stdout = tokio::io::BufReader::new(child.stdout.take().expect("child stdout")).lines();
    tokio::time::timeout(Duration::from_secs(8), async {
        loop {
            if stdout
                .next_line()
                .await
                .expect("child observation")
                .expect("child must reach cut")
                == marker
            {
                break;
            }
        }
    })
    .await
    .expect("bounded crash cut");
}
async fn kill(child: &mut tokio::process::Child) {
    child.start_kill().expect("real process kill");
    let status = tokio::time::timeout(Duration::from_secs(8), child.wait())
        .await
        .expect("kill exit bound")
        .expect("killed status");
    assert_eq!(
        status.signal(),
        Some(9),
        "must terminate by SIGKILL, not graceful drain"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn three_protocols_resume_after_committed_tool_process_kill() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    for (case, name) in [
        (Case::Chat, "chat"),
        (Case::Responses, "responses"),
        (Case::Messages, "messages"),
    ] {
        let directory = tempfile::tempdir().expect("persistent test directory");
        let mut peer = fixture::provider(vec![case.tool_reply(), case.text_reply()]).await;
        let endpoint = peer.endpoint.replace("/v1/chat/completions", case.path());
        tokio::fs::write(directory.path().join("root.pem"), &peer.root)
            .await
            .expect("test root");
        let mut prime = child(directory.path(), &endpoint, name, "prime")
            .stdout(std::process::Stdio::piped())
            .spawn()
            .expect("first OS owner");
        at_cut(&mut prime, READY).await;
        assert_eq!(
            peer.requests.recv().await.expect("first actual send"),
            case.first_request()
        );
        kill(&mut prime).await;
        let output = tokio::time::timeout(
            Duration::from_secs(8),
            child(directory.path(), &endpoint, name, "resume").output(),
        )
        .await
        .expect("restart exit bound")
        .expect("new process");
        assert!(
            output.status.success(),
            "{case:?}: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let followup = tokio::fs::read_to_string(directory.path().join("followup.json"))
            .await
            .expect("retained followup");
        let retained: serde_json::Value = serde_json::from_str(&followup).expect("stored JSON");
        match case {
            Case::Chat => {
                assert_eq!(retained["messages"][1]["tool_calls"][0]["id"], "call-1");
                assert_eq!(retained["messages"][2]["tool_call_id"], "call-1");
            }
            Case::Responses => {
                assert_eq!(retained["input"][1]["encrypted_content"], "opaque-keep");
                assert_eq!(retained["input"][2]["call_id"], "call-1");
                assert_eq!(retained["input"][3]["call_id"], "call-1");
            }
            Case::Messages => {
                assert_eq!(
                    retained["messages"][1]["content"][0]["signature"],
                    "sig-keep"
                );
                assert_eq!(
                    retained["messages"][1]["content"][1]["data"],
                    "opaque-redacted"
                );
                assert_eq!(retained["messages"][1]["content"][2]["id"], "call-1");
                assert_eq!(
                    retained["messages"][2]["content"][0]["tool_use_id"],
                    "call-1"
                );
            }
        }
        assert_eq!(
            peer.requests.recv().await.expect("second actual send"),
            followup
        );
        peer.finish()
            .await
            .expect("no extra connection or peer panic")
            .expect("complete fixture replies");
        let store = weaver_ledger::persistence::Session::open(directory.path().join("ledger.db"))
            .expect("durable state");
        let counts: (i64,i64,i64) = weaver_ledger::persistence::one(&store,
            "SELECT (SELECT COUNT(*) FROM provider_session_turns), (SELECT COUNT(*) FROM provider_runs), (SELECT COUNT(*) FROM provider_terminal_usage WHERE tokens='[2,0,0,3]')", (),
            |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?))).expect("durable claims and usage");
        assert_eq!(
            counts,
            (3, 2, 2),
            "{case:?}: process kill must retain claims and terminal usage"
        );
        let roots: (i64,i64) = weaver_ledger::persistence::one(&store,
            "SELECT COUNT(DISTINCT budget_root),COUNT(DISTINCT history_root) FROM execution_origins", (),
            |r|Ok((r.get(0)?,r.get(1)?))).expect("shared roots");
        assert_eq!(
            roots,
            (1, 1),
            "process restart cannot mint another budget/history"
        );
        store.close().expect("close ledger");
    }
}
