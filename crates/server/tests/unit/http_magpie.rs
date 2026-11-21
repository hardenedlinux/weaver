// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Explicit external-consumer acceptance; no Magpie source is patched here.
use super::{Harness, completed_models, fixture, protocol::Case};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::io::AsyncWriteExt;

fn command(binary: &Path, home: &Path, proxy: &str) -> tokio::process::Command {
    let mut c = tokio::process::Command::new(binary);
    c.env_clear()
        .current_dir(home)
        .kill_on_drop(true)
        .env("HOME", home)
        .env("USERPROFILE", home)
        .env("XDG_CONFIG_HOME", home.join("config"))
        .env("XDG_CONFIG_DIRS", home.join("etc"))
        .env("XDG_CACHE_HOME", home.join("cache"))
        .env("XDG_DATA_HOME", home.join("data"))
        .env("XDG_STATE_HOME", home.join("state"))
        .env("APPDATA", home.join("appdata"))
        .env("LOCALAPPDATA", home.join("localappdata"))
        .env("PATH", home.join("bin"))
        .env("TMPDIR", home.join("tmp"))
        .env("MAGPIE_TEST_SANDBOX", home)
        .env("MAGPIE_ADDR", "127.0.0.1:0")
        .env("MAGPIE_NO_STATS", "1")
        .env("DO_NOT_TRACK", "1")
        .env("HTTP_PROXY", proxy)
        .env("HTTPS_PROXY", proxy)
        .env("ALL_PROXY", proxy)
        .env("NO_PROXY", "127.0.0.1,localhost");
    c
}
async fn output(c: &mut tokio::process::Command) -> std::process::Output {
    let result = tokio::time::timeout(Duration::from_secs(20), c.output())
        .await
        .expect("CLI deadline")
        .expect("CLI invocation");
    assert!(
        result.status.success(),
        "CLI failed: {}\n{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    result
}
async fn submit(client: &reqwest::Client, base: &str, case: Case, raw: &str) -> reqwest::Response {
    let mut body: serde_json::Value = serde_json::from_str(raw).expect("harness JSON");
    body["model"] = "weaver/model-a".into();
    let request = client
        .post(format!("{base}{}", case.path()))
        .header("content-type", "application/json")
        .body(body.to_string());
    let request = if matches!(case, Case::Messages) {
        request
            .header("x-api-key", "magpie")
            .header("anthropic-version", "2023-06-01")
    } else {
        request.bearer_auth("magpie")
    };
    request.send().await.expect("actual Magpie request")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "external consumer: set WEAVER_MAGPIE_BIN to a separately prepared Magpie nogui CLI"]
async fn magpie_standard_provider_preserves_three_protocol_tool_turns() {
    let binary = PathBuf::from(
        std::env::var_os("WEAVER_MAGPIE_BIN").expect("prepared Magpie executable required"),
    );
    assert!(binary.is_absolute() && binary.is_file());
    let denied = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("deny proxy");
    let proxy = format!("http://{}", denied.local_addr().expect("proxy address"));
    let stopping = tokio_util::sync::CancellationToken::new();
    let stop = stopping.clone();
    let deny = tokio::spawn(async move {
        loop {
            let accepted = tokio::select! { v=denied.accept()=>v, ()=stop.cancelled()=>break };
            let (mut socket, _) = accepted.expect("proxy accept");
            let _ = socket
                .write_all(
                    b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await;
        }
    });
    for case in [Case::Chat, Case::Responses, Case::Messages] {
        let directory = tempfile::tempdir().expect("isolated consumer");
        let home = directory.path();
        tokio::fs::create_dir_all(home.join("bin"))
            .await
            .expect("empty PATH");
        tokio::fs::create_dir_all(home.join("tmp"))
            .await
            .expect("temporary files");
        let mut peer = fixture::provider(vec![case.tool_reply(), case.text_reply()]).await;
        let endpoint = peer.endpoint.replace("/v1/chat/completions", case.path());
        let database = home.join("ledger.db");
        let owner = Harness::start(&database, &peer.root, Some((&endpoint, case.protocol()))).await;
        let field = match case {
            Case::Chat => "chat",
            Case::Responses => "responses",
            Case::Messages => "anthropic",
        };
        let added = output(command(&binary, home, &proxy).args([
            "provider",
            "add",
            "Weaver",
            "id=weaver",
            "key=http-client-secret",
            "models=model-a",
            &format!("{field}={}/v1", owner.base),
            &format!("models.url={}/v1/models", owner.base),
        ]))
        .await;
        let announcement = String::from_utf8_lossy(&added.stdout);
        assert!(
            announcement.contains("models from"),
            "{case:?}: Provider discovery must actually read Weaver's live catalog: {announcement}"
        );
        let configured: serde_json::Value = serde_json::from_slice(
            &tokio::fs::read(home.join("config/magpie/providers.json"))
                .await
                .expect("original Provider config"),
        )
        .expect("Provider JSON");
        assert!(configured.to_string().contains("http-client-secret"));
        let mut serve = command(&binary, home, &proxy)
            .arg("serve")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("stock Magpie host");
        let base = tokio::time::timeout(Duration::from_secs(8), async {
            let mut tick = tokio::time::interval(Duration::from_millis(20));
            loop {
                assert!(
                    serve.try_wait().expect("host state").is_none(),
                    "Magpie exited before listener"
                );
                if let Ok(bytes) = tokio::fs::read(home.join("config/magpie/gateway.json")).await {
                    let metadata: serde_json::Value =
                        serde_json::from_slice(&bytes).expect("original listener record");
                    assert_eq!(metadata["pid"].as_u64(), serve.id().map(u64::from));
                    let addr: std::net::SocketAddr = metadata["addr"]
                        .as_str()
                        .expect("listener")
                        .parse()
                        .expect("actual bound address");
                    assert!(addr.ip().is_loopback() && addr.port() != 0);
                    break format!("http://{addr}");
                }
                tick.tick().await;
            }
        })
        .await
        .expect("listener readiness bound");
        let client = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(8))
            .build()
            .expect("client");
        let catalog = client
            .get(format!("{base}/v1/models"))
            .bearer_auth("magpie")
            .send()
            .await
            .expect("actual Magpie catalog")
            .error_for_status()
            .expect("catalog status")
            .bytes()
            .await
            .expect("catalog bytes");
        let catalog: serde_json::Value = serde_json::from_slice(&catalog).expect("catalog JSON");
        assert!(
            catalog["data"]
                .as_array()
                .expect("model list")
                .iter()
                .any(|v| v["id"] == "weaver/model-a")
        );
        let first = completed_models(
            submit(&client, &base, case, &case.first_request()).await,
            case,
            &["model-a", "weaver/model-a"],
        )
        .await;
        assert_eq!(first.calls.len(), 1);
        assert_eq!(first.calls[0].id, "call-1");
        assert_eq!(first.calls[0].name, "read");
        assert_eq!(first.calls[0].arguments, serde_json::json!({"path":"file"}));
        match case {
            Case::Responses => assert_eq!(
                first.opaque.as_ref().expect("reasoning")[0]["encrypted_content"],
                "opaque-keep"
            ),
            Case::Messages => {
                let blocks = first.opaque.as_ref().expect("blocks");
                assert_eq!(blocks[0]["signature"], "sig-keep");
                assert_eq!(blocks[1]["data"], "opaque-redacted");
            }
            Case::Chat => {}
        }
        let next = case.followup(&first.calls, first.opaque);
        let second = completed_models(
            submit(&client, &base, case, &next).await,
            case,
            &["model-a", "weaver/model-a"],
        )
        .await;
        assert_eq!(second.text, "hello");
        assert!(second.calls.is_empty());
        let mut forwarded = Vec::new();
        for _ in 0..2 {
            let raw = peer.requests.recv().await.expect("actual forwarded body");
            let value: serde_json::Value = serde_json::from_str(&raw).expect("upstream JSON");
            assert_eq!(value["model"], "model-a");
            forwarded.push(raw);
        }
        serve.start_kill().expect("stop isolated host");
        tokio::time::timeout(Duration::from_secs(5), serve.wait_with_output())
            .await
            .expect("host exit deadline")
            .expect("host exit");
        owner.finish().await;
        peer.finish()
            .await
            .expect("no extra upstream connection")
            .expect("two complete replies");
        let store =
            weaver_ledger::persistence::Session::open(&database).expect("durable native ledger");
        let counts:(i64,i64,i64,i64)=weaver_ledger::persistence::one(&store,
            "SELECT (SELECT COUNT(*) FROM provider_runs),COUNT(DISTINCT budget_root),COUNT(DISTINCT history_root),(SELECT COUNT(*) FROM provider_terminal_usage) FROM execution_origins",(),
            |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).expect("shared authority");
        assert_eq!(counts, (2, 1, 1, 2));
        for body in forwarded {
            let digest = weaver_contracts::body_digest(&body);
            let matched:i64=weaver_ledger::persistence::one(&store,
                "SELECT COUNT(*) FROM provider_session_turns s JOIN tasks t ON t.family=s.family WHERE json_extract(t.record,'$.body_digests.infer')=?1",[digest],|r|r.get(0)).expect("exact forwarded commitment");
            assert_eq!(
                matched, 1,
                "exact actual upstream bytes must match retained admission"
            );
        }
        store.close().expect("SQL close");
    }
    stopping.cancel();
    deny.await.expect("deny proxy stopped");
}
