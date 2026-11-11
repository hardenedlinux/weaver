// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{TestResult, messages};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    sync::{Mutex, Notify},
    task::{JoinHandle, JoinSet},
    time::timeout,
};
use weaver_llm::{Configuration, Error, Options, PreparedProfile};

const WATCHDOG: Duration = Duration::from_secs(5);

#[derive(Default)]
struct Observed {
    polls: AtomicUsize,
    exchanges: AtomicUsize,
    parent_refreshes: AtomicUsize,
    models: AtomicUsize,
    pending: AtomicBool,
    expiring_parent: AtomicBool,
    block_parent: AtomicBool,
    deny_parent: AtomicBool,
    omit_rotation: AtomicBool,
    omit_refresh_expiry: AtomicBool,
    block: AtomicBool,
    deny_model: AtomicBool,
    fault: AtomicUsize,
    device_error: AtomicUsize,
    redirect: Mutex<Option<String>>,
    arrived: Notify,
    release: Notify,
}

struct Fixture {
    _directory: tempfile::TempDir,
    config: PathBuf,
    token: PathBuf,
    observed: Arc<Observed>,
    server: JoinHandle<()>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl Fixture {
    async fn new() -> TestResult<Self> {
        let directory = tempfile::tempdir()?;
        let config = directory.path().join("weaver.toml");
        let token = directory.path().join("auth/tokens.json");
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let issuer = format!("http://{}", listener.local_addr()?);
        let observed = Arc::new(Observed::default());
        let owned = observed.clone();
        let base = issuer.clone();
        let server = tokio::spawn(async move {
            let mut tasks = JoinSet::new();
            loop {
                tokio::select! {
                    connection = listener.accept() => {
                        let Ok((socket, _)) = connection else { break; };
                        let observed = owned.clone();
                        let issuer = base.clone();
                        tasks.spawn(async move { let _ = handle(socket,&issuer,observed).await; });
                    }
                    _ = tasks.join_next(), if !tasks.is_empty() => {}
                }
            }
        });
        tokio::fs::write(
            &config,
            format!(
                r#"
[profiles.local]
kind = "direct"
protocol = "openai-chat-completions"
endpoint = "{issuer}/api/chat/completions"
model = "configured"
timeout_ms = 1000
max_response_bytes = 4096
[profiles.local.credential.copilot]
client_id = "snake-oil-harness"
device_authorization_url = "{issuer}/device"
token_url = "{issuer}/github-token"
api_token_url = "{issuer}/api-token"
api_base = "{issuer}/api"
token_file = "auth/tokens.json"
login_timeout_ms = 2000
"#
            ),
        )
        .await?;
        Ok(Self {
            _directory: directory,
            config,
            token,
            observed,
            server,
        })
    }

    async fn prepare(&self) -> Result<PreparedProfile, Error> {
        Configuration::load(&self.config)
            .await?
            .prepare("local")
            .await
    }

    async fn login(&self, profile: &PreparedProfile) -> TestResult {
        let attempt = profile
            .oauth()
            .ok_or("missing owner")?
            .start_device_authorization()
            .await?;
        assert_eq!(attempt.user_code(), "LOGIN");
        assert!(attempt.verification_uri().ends_with("/verify"));
        attempt.finish().await?;
        Ok(())
    }

    async fn alter(&self, field: &str, value: Value) -> TestResult {
        let mut record: Value = serde_json::from_slice(&tokio::fs::read(&self.token).await?)?;
        match field {
            "api_expiry" => {
                record["token"]["issued_at"] = json!(1);
                record["token"]["expires_at"] = json!(2);
                record["token"]["refresh_at"] = json!(2);
            }
            "refresh_hint" => {
                record["token"]["issued_at"] = json!(1);
                record["token"]["refresh_at"] = json!(2);
            }
            "parent_expiry" => {
                record["copilot_parent"]["issued_at"] = json!(1);
                record["copilot_parent"]["expires_at"] = json!(2);
            }
            "refresh_expiry" => {
                record["copilot_parent"]["issued_at"] = json!(1);
                record["copilot_parent"]["expires_at"] = json!(2);
                record["copilot_parent"]["refresh_expires_at"] = json!(2);
            }
            _ => record[field] = value,
        }
        tokio::fs::write(&self.token, serde_json::to_vec(&record)?).await?;
        Ok(())
    }
}

async fn handle(socket: TcpStream, issuer: &str, o: Arc<Observed>) -> TestResult {
    let mut socket = BufReader::new(socket);
    let mut headers = String::new();
    let mut length = 0;
    loop {
        let mut line = String::new();
        if socket.read_line(&mut line).await? == 0 {
            return Err("missing headers".into());
        }
        if let Some((name, value)) = line.split_once(':')
            && name.eq_ignore_ascii_case("content-length")
        {
            length = value.trim().parse()?;
        }
        headers.push_str(&line);
        if line == "\r\n" {
            break;
        }
    }
    let mut bytes = vec![0; length];
    socket.read_exact(&mut bytes).await?;
    let form: BTreeMap<_, _> = oauth2::url::form_urlencoded::parse(&bytes)
        .into_owned()
        .collect();
    let h = headers.to_ascii_lowercase();
    assert!(h.contains("user-agent: weaver/"));
    let mut status = "200 OK";
    let mut extra = String::new();
    let response = if h.starts_with("post /device ") {
        assert_eq!(form["client_id"], "snake-oil-harness");
        assert_eq!(form["scope"], "read:user");
        assert!(!h.contains("authorization:"));
        json!({"device_code":"private-device-code","user_code":"LOGIN","verification_uri":format!("{issuer}/verify"),"expires_in":60,"interval":1})
    } else if h.starts_with("post /github-token ") {
        if form.get("grant_type").is_some_and(|v| v == "refresh_token") {
            let n = o.parent_refreshes.fetch_add(1, Ordering::SeqCst);
            assert_eq!(form["client_id"], "snake-oil-harness");
            assert_eq!(form["refresh_token"], format!("github-refresh-{n}"));
            if o.block_parent.load(Ordering::SeqCst) {
                o.arrived.notify_one();
                o.release.notified().await;
            }
            if o.deny_parent.load(Ordering::SeqCst) {
                status = "400 Bad Request";
                json!({"error":"invalid_grant"})
            } else {
                github_grant(&o, n + 1)
            }
        } else {
            assert_eq!(
                form["grant_type"],
                "urn:ietf:params:oauth:grant-type:device_code"
            );
            assert_eq!(form["device_code"], "private-device-code");
            assert_eq!(form["client_id"], "snake-oil-harness");
            assert!(!h.contains("authorization:"));
            o.polls.fetch_add(1, Ordering::SeqCst);
            match o.device_error.load(Ordering::SeqCst) {
                1 => json!({"error":"access_denied"}),
                2 => json!({"error":"expired_token"}),
                3 => json!({"error":"slow_down","interval":6}),
                4 => json!({"error":"authorization_pending","access_token":"ambiguous"}),
                _ if o.pending.swap(false, Ordering::SeqCst) => {
                    json!({"error":"authorization_pending"})
                }
                _ => github_grant(&o, 0),
            }
        }
    } else if h.starts_with("get /api-token ") {
        assert!(h.contains("authorization: token github-parent-only\r\n"));
        assert!(h.contains("x-github-api-version: 2025-04-01"));
        let n = o.exchanges.fetch_add(1, Ordering::SeqCst) + 1;
        if o.block.load(Ordering::SeqCst) {
            o.arrived.notify_one();
            o.release.notified().await;
        }
        if let Some(target) = o.redirect.lock().await.as_ref() {
            status = "307 Temporary Redirect";
            extra = format!("Location: {target}\r\n");
        }
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        match o.fault.load(Ordering::SeqCst) {
            1 => {
                status = "401 Unauthorized";
                json!({"secret":"must-not-escape"})
            }
            2 => {
                status = "503 Service Unavailable";
                json!({"secret":"must-not-escape"})
            }
            3 => {
                json!({"token":"api-only","expires_at":now+3600,"refresh_in":1800,"endpoints":{"api":"https://substituted.invalid"}})
            }
            4 => json!({"token":"api-only","expires_at":now,"refresh_in":1800}),
            5 => json!({"token":"api-only","expires_at":now+3600,"refresh_in":0}),
            6 => {
                json!({"token":"api-only\r\nX-Injected: yes","expires_at":now+3600,"refresh_in":1800})
            }
            7 => json!({"token":"x".repeat(70*1024),"expires_at":now+3600,"refresh_in":1800}),
            9 => {
                status = "403 Forbidden";
                json!({"secret":"must-not-escape"})
            }
            10 => json!({"token":"api-only","expires_at":now+3600,"refresh_in":u64::MAX}),
            _ => {
                json!({"token":format!("copilot-api-{n}"),"expires_at":now+3600,"refresh_in":1800,"endpoints":{"api":format!("{issuer}/api")}})
            }
        }
    } else {
        assert!(h.starts_with("post /api/chat/completions "));
        assert!(!h.contains("github-parent-only"));
        assert!(!h.contains("private-device-code"));
        let n = o.exchanges.load(Ordering::SeqCst);
        assert!(h.contains(&format!("authorization: bearer copilot-api-{n}\r\n")));
        assert!(h.contains("copilot-integration-id: vscode-chat"));
        assert!(h.contains("editor-version: weaver/"));
        o.models.fetch_add(1, Ordering::SeqCst);
        if o.deny_model.swap(false, Ordering::SeqCst) {
            status = "401 Unauthorized";
        }
        let body: Value = serde_json::from_slice(&bytes)?;
        if body["stream"] == true {
            let sse = "data: {\"id\":\"one\",\"model\":\"configured\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"},\"finish_reason\":null}]}\n\ndata: {\"id\":\"one\",\"model\":\"configured\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
            socket.get_mut().write_all(format!("HTTP/1.1 {status}\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{sse}",sse.len()).as_bytes()).await?;
            return Ok(());
        }
        json!({"id":"one","model":"configured","choices":[{"index":0,"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}]})
    };
    let body = response.to_string();
    socket.get_mut().write_all(format!("HTTP/1.1 {status}\r\n{extra}Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await?;
    Ok(())
}

fn github_grant(o: &Observed, refresh: usize) -> Value {
    let mut value = json!({"access_token":"github-parent-only","token_type":"bearer",
        "scope":if o.fault.load(Ordering::SeqCst)==8 {"read:user admin"} else {"read:user"}});
    if o.expiring_parent.load(Ordering::SeqCst) {
        value["expires_in"] = json!(3600);
        if refresh == 0 || !o.omit_rotation.load(Ordering::SeqCst) {
            value["refresh_token"] = json!(format!("github-refresh-{refresh}"));
            if refresh == 0 || !o.omit_refresh_expiry.load(Ordering::SeqCst) {
                value["refresh_token_expires_in"] = json!(86400);
            }
        } else if let Some(fields) = value.as_object_mut() {
            fields.remove("scope");
        }
    }
    value
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn device_parent_and_api_lease_remain_separate_across_restart_and_four_callers() -> TestResult
{
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        f.observed.pending.store(true, Ordering::SeqCst);
        let p = f.prepare().await?;
        f.login(&p).await?;
        assert_eq!(
            p.complete(&messages(), &Options::default()).await?.choices[0]
                .message
                .content,
            "Hi"
        );
        let mut turn = p.stream_turn(&messages(), &Options::default()).await?;
        while turn.next_event().await?.is_some() {}
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        drop(p);
        let restored = f.prepare().await?;
        restored.complete(&messages(), &Options::default()).await?;
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        drop(restored);
        f.alter("api_expiry", Value::Null).await?;
        let p = Arc::new(f.prepare().await?);
        let mut tasks = JoinSet::new();
        for _ in 0..4 {
            let p = p.clone();
            tasks.spawn(async move { p.complete(&messages(), &Options::default()).await });
        }
        while let Some(result) = tasks.join_next().await {
            result??;
        }
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 2);
        assert_eq!(f.observed.polls.load(Ordering::SeqCst), 2);
        assert_eq!(f.observed.models.load(Ordering::SeqCst), 7);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn refresh_hint_expires_before_the_absolute_api_lease() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let p = f.prepare().await?;
        f.login(&p).await?;
        drop(p);
        f.alter("refresh_hint", Value::Null).await?;
        let p = f.prepare().await?;
        p.complete(&messages(), &Options::default()).await?;
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 2);
        assert_eq!(f.observed.polls.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancelled_api_exchange_recovers_parent_without_replaying_device_grant() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let p = f.prepare().await?;
        f.observed.block.store(true, Ordering::SeqCst);
        let attempt = p
            .oauth()
            .ok_or("missing owner")?
            .start_device_authorization()
            .await?;
        let task = tokio::spawn(attempt.finish());
        f.observed.arrived.notified().await;
        task.abort();
        assert!(task.await.is_err());
        drop(p);
        f.observed.block.store(false, Ordering::SeqCst);
        f.observed.release.notify_one();
        let restored = f.prepare().await?;
        restored.complete(&messages(), &Options::default()).await?;
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 2);
        assert_eq!(f.observed.polls.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rejected_parent_requires_login_but_transient_get_can_be_requested_again() -> TestResult {
    timeout(WATCHDOG, async {
        for fault in [1, 2, 9] {
            let f = Fixture::new().await?;
            let p = f.prepare().await?;
            f.observed.fault.store(fault, Ordering::SeqCst);
            let error = f.login(&p).await.expect_err("denied exchange");
            let text = error.to_string();
            assert!(!text.contains("must-not-escape"));
            assert!(!text.contains("github-parent-only"));
            assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
            drop(p);
            f.observed.fault.store(0, Ordering::SeqCst);
            let restored = f.prepare().await?;
            let result = restored.complete(&messages(), &Options::default()).await;
            if fault == 2 {
                result?;
                assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 2);
            } else {
                assert!(matches!(result, Err(Error::Authentication)));
                assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
            }
            assert_eq!(f.observed.polls.load(Ordering::SeqCst), 1);
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn invalid_lease_destination_expiry_scope_and_size_never_reach_model() -> TestResult {
    timeout(WATCHDOG, async {
        for fault in [3, 4, 5, 6, 7, 8, 10] {
            let f = Fixture::new().await?;
            let p = f.prepare().await?;
            f.login(&p).await?;
            p.complete(&messages(), &Options::default()).await?;
            f.observed.fault.store(fault, Ordering::SeqCst);
            assert!(f.login(&p).await.is_err());
            assert!(p.complete(&messages(), &Options::default()).await.is_err());
            assert_eq!(f.observed.models.load(Ordering::SeqCst), 1);
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn logout_clears_both_stages_and_rejects_late_device_completion() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let p = f.prepare().await?;
        f.login(&p).await?;
        let owner = p.oauth().ok_or("missing owner")?;
        let stale = owner.start_device_authorization().await?;
        owner.logout().await?;
        assert!(matches!(stale.finish().await, Err(Error::Authentication)));
        drop(p);
        let restored = f.prepare().await?;
        assert!(matches!(
            restored.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        assert_eq!(f.observed.polls.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        let record: Value = serde_json::from_slice(&tokio::fs::read(&f.token).await?)?;
        assert!(record.get("copilot_parent").is_none());
        assert!(record["token"].is_null());
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn api_401_invalidates_only_its_lease_without_replaying_the_model_call() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let p = f.prepare().await?;
        f.login(&p).await?;
        f.observed.deny_model.store(true, Ordering::SeqCst);
        assert!(matches!(
            p.complete(&messages(), &Options::default()).await,
            Err(Error::Status(401))
        ));
        assert_eq!(f.observed.models.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        p.complete(&messages(), &Options::default()).await?;
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 2);
        assert_eq!(f.observed.polls.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn expired_parent_cannot_refresh_or_send_an_unexpired_api_lease() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let p = f.prepare().await?;
        f.login(&p).await?;
        drop(p);
        f.alter("parent_expiry", Value::Null).await?;
        let p = f.prepare().await?;
        assert!(matches!(
            p.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        assert_eq!(f.observed.models.load(Ordering::SeqCst), 0);
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn github_http_200_device_errors_obey_denial_and_original_deadline() -> TestResult {
    timeout(WATCHDOG, async {
        for error in [1, 2, 3, 4] {
            let f = Fixture::new().await?;
            let p = f.prepare().await?;
            f.observed.device_error.store(error, Ordering::SeqCst);
            assert!(f.login(&p).await.is_err());
            assert_eq!(f.observed.polls.load(Ordering::SeqCst), 1);
            assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 0);
            assert_eq!(f.observed.models.load(Ordering::SeqCst), 0);
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn api_redirect_does_not_forward_the_upstream_github_credential() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let p = f.prepare().await?;
        let target = TcpListener::bind("127.0.0.1:0").await?;
        *f.observed.redirect.lock().await = Some(format!("http://{}/steal", target.local_addr()?));
        assert!(f.login(&p).await.is_err());
        assert!(
            timeout(Duration::from_millis(50), target.accept())
                .await
                .is_err()
        );
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.models.load(Ordering::SeqCst), 0);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rotating_parent_refresh_is_shared_and_persists_across_restart() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        f.observed.expiring_parent.store(true, Ordering::SeqCst);
        let p = f.prepare().await?;
        f.login(&p).await?;
        drop(p);
        f.alter("parent_expiry", Value::Null).await?;
        let p = Arc::new(f.prepare().await?);
        let mut tasks = JoinSet::new();
        for _ in 0..4 {
            let p = p.clone();
            tasks.spawn(async move { p.complete(&messages(), &Options::default()).await });
        }
        while let Some(result) = tasks.join_next().await {
            result??;
        }
        assert_eq!(f.observed.parent_refreshes.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 2);
        drop(p);
        f.alter("parent_expiry", Value::Null).await?;
        let restored = f.prepare().await?;
        restored.complete(&messages(), &Options::default()).await?;
        assert_eq!(f.observed.parent_refreshes.load(Ordering::SeqCst), 2);
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 3);
        assert_eq!(f.observed.polls.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancelled_parent_refresh_is_not_replayed_after_restart() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        f.observed.expiring_parent.store(true, Ordering::SeqCst);
        let p = f.prepare().await?;
        f.login(&p).await?;
        drop(p);
        f.alter("parent_expiry", Value::Null).await?;
        let p = Arc::new(f.prepare().await?);
        let owned = p.clone();
        f.observed.block_parent.store(true, Ordering::SeqCst);
        let task =
            tokio::spawn(async move { owned.complete(&messages(), &Options::default()).await });
        f.observed.arrived.notified().await;
        task.abort();
        assert!(task.await.is_err());
        drop(p);
        f.observed.block_parent.store(false, Ordering::SeqCst);
        f.observed.release.notify_one();
        let restored = f.prepare().await?;
        assert!(matches!(
            restored.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        assert_eq!(f.observed.parent_refreshes.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.models.load(Ordering::SeqCst), 0);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn expired_or_rejected_parent_refresh_cannot_activate_either_stage() -> TestResult {
    timeout(WATCHDOG, async {
        for expired in [false, true] {
            let f = Fixture::new().await?;
            f.observed.expiring_parent.store(true, Ordering::SeqCst);
            let p = f.prepare().await?;
            f.login(&p).await?;
            drop(p);
            f.alter(
                if expired {
                    "refresh_expiry"
                } else {
                    "parent_expiry"
                },
                Value::Null,
            )
            .await?;
            f.observed.deny_parent.store(true, Ordering::SeqCst);
            let p = f.prepare().await?;
            assert!(matches!(
                p.complete(&messages(), &Options::default()).await,
                Err(Error::Authentication)
            ));
            drop(p);
            let restored = f.prepare().await?;
            assert!(matches!(
                restored.complete(&messages(), &Options::default()).await,
                Err(Error::Authentication)
            ));
            assert_eq!(
                f.observed.parent_refreshes.load(Ordering::SeqCst),
                usize::from(!expired)
            );
            assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
            assert_eq!(f.observed.models.load(Ordering::SeqCst), 0);
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn omitted_rotation_metadata_preserves_the_original_refresh_deadline() -> TestResult {
    timeout(WATCHDOG, async {
        for omit_rotation in [false, true] {
            let f = Fixture::new().await?;
            f.observed.expiring_parent.store(true, Ordering::SeqCst);
            let p = f.prepare().await?;
            f.login(&p).await?;
            drop(p);
            let original: Value = serde_json::from_slice(&tokio::fs::read(&f.token).await?)?;
            let expiry = original["copilot_parent"]["refresh_expires_at"].clone();
            f.alter("parent_expiry", Value::Null).await?;
            f.observed
                .omit_rotation
                .store(omit_rotation, Ordering::SeqCst);
            f.observed.omit_refresh_expiry.store(true, Ordering::SeqCst);
            let p = f.prepare().await?;
            p.complete(&messages(), &Options::default()).await?;
            drop(p);
            let record: Value = serde_json::from_slice(&tokio::fs::read(&f.token).await?)?;
            assert_eq!(
                record["copilot_parent"]["refresh"],
                if omit_rotation {
                    "github-refresh-0"
                } else {
                    "github-refresh-1"
                }
            );
            assert_eq!(record["copilot_parent"]["refresh_expires_at"], expiry);
            let restored = f.prepare().await?;
            restored.complete(&messages(), &Options::default()).await?;
            assert_eq!(f.observed.parent_refreshes.load(Ordering::SeqCst), 1);
            assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 2);
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn changing_model_protocol_or_api_base_cannot_rebind_saved_credentials() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let p = f.prepare().await?;
        f.login(&p).await?;
        drop(p);
        let original = tokio::fs::read_to_string(&f.config).await?;
        for text in [
            original.replace("model = \"configured\"", "model = \"substituted\""),
            original.replace("openai-chat-completions", "anthropic-messages"),
            original.replace("/api\"", "/different-api\""),
            original.replace("/api/chat/completions", "/api-escape/chat/completions"),
        ] {
            tokio::fs::write(&f.config, text).await?;
            assert!(matches!(f.prepare().await, Err(Error::Configuration)));
        }
        tokio::fs::write(&f.config, original).await?;
        let restored = f.prepare().await?;
        restored.complete(&messages(), &Options::default()).await?;
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.polls.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}
