// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{TestResult, messages};
use base64::Engine;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
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
    grants: AtomicUsize,
    refreshes: AtomicUsize,
    polls: AtomicUsize,
    block_refresh: AtomicBool,
    deny_refresh: AtomicBool,
    broad_scope: AtomicBool,
    redirect_token: AtomicBool,
    deny_model: AtomicBool,
    block_model: AtomicBool,
    device_error: AtomicUsize,
    poll_times: Mutex<Vec<tokio::time::Instant>>,
    pkce: Mutex<Option<String>>,
    arrived: Notify,
    release: Notify,
    requests: Mutex<Vec<(String, String)>>,
}

struct Fixture {
    _directory: tempfile::TempDir,
    config: PathBuf,
    token: PathBuf,
    issuer: String,
    model_endpoint: String,
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
        Self::with_model_endpoint(None).await
    }

    async fn with_model_endpoint(endpoint: Option<String>) -> TestResult<Self> {
        let directory = tempfile::tempdir()?;
        let config = directory.path().join("weaver.toml");
        let token = directory.path().join("auth/tokens.json");
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let issuer = format!("http://{}", listener.local_addr()?);
        let model_endpoint = endpoint.unwrap_or_else(|| format!("{issuer}/model"));
        let observed = Arc::new(Observed::default());
        let task_observed = observed.clone();
        let task_issuer = issuer.clone();
        let server = tokio::spawn(async move {
            let mut tasks = JoinSet::new();
            loop {
                tokio::select! {
                    connection = listener.accept() => {
                        let Ok((socket, _)) = connection else { break; };
                        let observed = task_observed.clone();
                        let issuer = task_issuer.clone();
                        tasks.spawn(async move { let _ = handle(socket, &issuer, observed).await; });
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
endpoint = "{model_endpoint}"
model = "configured"
timeout_ms = 1000
max_response_bytes = 4096
[profiles.local.credential.oauth]
client_id = "snake-oil-harness"
token_url = "{issuer}/token"
authorization_url = "{issuer}/authorize"
device_authorization_url = "{issuer}/device"
redirect_uri = "http://127.0.0.1:1455/callback"
resource = "{model_endpoint}"
scopes = ["read"]
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
            issuer,
            model_endpoint,
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
        let session = profile.oauth().ok_or("missing OAuth owner")?;
        let attempt = session.start_authorization().await?;
        let url = oauth2::url::Url::parse(attempt.authorization_url())?;
        let parameters: BTreeMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(parameters["code_challenge_method"], "S256");
        assert_eq!(parameters["client_id"], "snake-oil-harness");
        assert_eq!(parameters["resource"], self.model_endpoint);
        *self.observed.pkce.lock().await = Some(parameters["code_challenge"].clone());
        let callback = format!(
            "http://127.0.0.1:1455/callback?code=one-time-code&state={}",
            parameters["state"]
        );
        attempt.finish(&callback).await?;
        Ok(())
    }

    async fn expire(&self) -> TestResult {
        let mut record: Value = serde_json::from_slice(&tokio::fs::read(&self.token).await?)?;
        record["token"]["issued_at"] = json!(1);
        record["token"]["expires_at"] = json!(2);
        tokio::fs::write(&self.token, serde_json::to_vec(&record)?).await?;
        Ok(())
    }
}

async fn handle(socket: TcpStream, issuer: &str, observed: Arc<Observed>) -> TestResult {
    let mut socket = BufReader::new(socket);
    let mut header = String::new();
    let mut length = 0;
    loop {
        let mut line = String::new();
        if socket.read_line(&mut line).await? == 0 {
            return Err("incomplete request".into());
        }
        if line == "\r\n" {
            break;
        }
        if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            length = value.trim().parse()?;
        }
        header.push_str(&line);
        if header.len() > 16384 {
            return Err("oversized test headers".into());
        }
    }
    if length > 16384 {
        return Err("oversized test body".into());
    }
    let mut body = vec![0; length];
    socket.read_exact(&mut body).await?;
    observed.requests.lock().await.push((
        header.to_ascii_lowercase(),
        String::from_utf8(body.clone())?,
    ));
    let form: BTreeMap<_, _> = oauth2::url::form_urlencoded::parse(&body)
        .into_owned()
        .collect();
    let mut status = "200 OK";
    if header.starts_with("POST /token ") && observed.redirect_token.load(Ordering::SeqCst) {
        observed.grants.fetch_add(1, Ordering::SeqCst);
        socket.get_mut().write_all(format!("HTTP/1.1 307 Temporary Redirect\r\nLocation: {issuer}/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await?;
        return Ok(());
    }
    let response = if header.starts_with("POST /model ") {
        if observed.block_model.swap(false, Ordering::SeqCst) {
            observed.arrived.notify_one();
            observed.release.notified().await;
        }
        if observed.deny_model.swap(false, Ordering::SeqCst) {
            status = "401 Unauthorized";
        }
        json!({"id":"one","model":"configured","choices":[{"index":0,"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}]})
    } else if header.starts_with("POST /device ") {
        json!({"device_code":"private-device-code","user_code":"LOGIN","verification_uri":format!("{issuer}/verify"),"expires_in":60,"interval":1})
    } else if form
        .get("grant_type")
        .is_some_and(|g| g.contains("device_code"))
    {
        assert_eq!(form["device_code"], "private-device-code");
        observed
            .poll_times
            .lock()
            .await
            .push(tokio::time::Instant::now());
        let poll = observed.polls.fetch_add(1, Ordering::SeqCst);
        let error = match observed.device_error.load(Ordering::SeqCst) {
            1 => Some("access_denied"),
            2 => Some("expired_token"),
            3 => Some("slow_down"),
            _ if poll == 0 => Some("authorization_pending"),
            _ => None,
        };
        if let Some(error) = error {
            status = "400 Bad Request";
            json!({"error":error})
        } else {
            token(&observed)
        }
    } else if form.get("grant_type").is_some_and(|g| g == "refresh_token") {
        let previous = observed.refreshes.fetch_add(1, Ordering::SeqCst);
        let expected = if previous == 0 {
            "snake-oil-refresh".to_owned()
        } else {
            format!("snake-oil-refresh-{previous}")
        };
        assert_eq!(form["refresh_token"], expected);
        observed.arrived.notify_one();
        if observed.block_refresh.load(Ordering::SeqCst) {
            observed.release.notified().await;
        }
        if observed.deny_refresh.load(Ordering::SeqCst) {
            status = "400 Bad Request";
            json!({"error":"invalid_grant","error_description":"secret-must-not-escape"})
        } else {
            token(&observed)
        }
    } else {
        observed.grants.fetch_add(1, Ordering::SeqCst);
        assert_eq!(form["grant_type"], "authorization_code");
        assert_eq!(form["code"], "one-time-code");
        assert_eq!(form["redirect_uri"], "http://127.0.0.1:1455/callback");
        assert!(form["code_verifier"].len() >= 43);
        use sha2::{Digest, Sha256};
        let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(Sha256::digest(form["code_verifier"].as_bytes()));
        assert_eq!(
            observed.pkce.lock().await.as_deref(),
            Some(challenge.as_str())
        );
        token(&observed)
    };
    let body = response.to_string();
    socket.get_mut().write_all(format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await?;
    Ok(())
}

fn token(observed: &Observed) -> Value {
    let refreshes = observed.refreshes.load(Ordering::SeqCst);
    let suffix = if refreshes == 0 {
        String::new()
    } else {
        format!("-{refreshes}")
    };
    json!({"access_token":format!("snake-oil-access{suffix}"),"token_type":"Bearer","expires_in":3600,
        "refresh_token":format!("snake-oil-refresh{suffix}"),"scope":if observed.broad_scope.load(Ordering::SeqCst) {"read admin"} else {"read"}})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rejected_access_token_is_not_reused_or_retried_after_restart() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        f.login(&profile).await?;
        f.observed.deny_model.store(true, Ordering::SeqCst);
        assert!(matches!(
            profile.complete(&messages(), &Options::default()).await,
            Err(Error::Status(401))
        ));
        assert!(matches!(
            profile.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        drop(profile);
        let restored = f.prepare().await?;
        assert!(matches!(
            restored.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        assert_eq!(
            f.observed
                .requests
                .lock()
                .await
                .iter()
                .filter(|r| r.0.starts_with("post /model "))
                .count(),
            1
        );
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn late_rejection_cannot_clear_a_newly_activated_credential() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = Arc::new(f.prepare().await?);
        f.login(&profile).await?;
        f.observed.block_model.store(true, Ordering::SeqCst);
        f.observed.deny_model.store(true, Ordering::SeqCst);
        let owned = profile.clone();
        let old =
            tokio::spawn(async move { owned.complete(&messages(), &Options::default()).await });
        f.observed.arrived.notified().await;
        f.login(&profile).await?;
        f.observed.release.notify_one();
        assert!(matches!(old.await?, Err(Error::Status(401))));
        profile.complete(&messages(), &Options::default()).await?;
        assert_eq!(f.observed.grants.load(Ordering::SeqCst), 2);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn tracked_store_shutdown_denies_new_work_and_allows_restart() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        f.login(&profile).await?;
        profile
            .oauth()
            .ok_or("missing OAuth owner")?
            .shutdown()
            .await;
        assert!(matches!(
            profile.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        drop(profile);
        let restored = f.prepare().await?;
        restored.complete(&messages(), &Options::default()).await?;
        let session = restored.oauth().ok_or("missing OAuth owner")?;
        session.logout().await?;
        session.shutdown().await;
        assert_eq!(f.observed.grants.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn login_restart_and_four_callers_share_one_refresh() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        f.login(&profile).await?;
        assert!(matches!(f.prepare().await, Err(Error::Configuration)));
        drop(profile);
        f.expire().await?;
        let profile = Arc::new(f.prepare().await?);
        let mut callers = JoinSet::new();
        for _ in 0..4 {
            let profile = profile.clone();
            callers.spawn(async move { profile.complete(&messages(), &Options::default()).await });
        }
        while let Some(result) = callers.join_next().await {
            assert_eq!(result??.choices[0].message.content, "Hi");
        }
        assert_eq!(f.observed.refreshes.load(Ordering::SeqCst), 1);
        let requests = f.observed.requests.lock().await;
        let model: Vec<_> = requests
            .iter()
            .filter(|r| r.0.starts_with("post /model "))
            .collect();
        assert_eq!(model.len(), 4);
        assert!(
            model
                .iter()
                .all(|r| r.0.contains("authorization: bearer snake-oil-access-1\r\n"))
        );
        drop(requests);
        drop(profile);
        f.expire().await?;
        f.prepare()
            .await?
            .complete(&messages(), &Options::default())
            .await?;
        assert_eq!(f.observed.refreshes.load(Ordering::SeqCst), 2);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancelled_refresh_stays_unknown_after_restart_without_replay() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        f.login(&profile).await?;
        drop(profile);
        f.expire().await?;
        f.observed.block_refresh.store(true, Ordering::SeqCst);
        let profile = Arc::new(f.prepare().await?);
        let owned = profile.clone();
        let call =
            tokio::spawn(async move { owned.complete(&messages(), &Options::default()).await });
        f.observed.arrived.notified().await;
        call.abort();
        assert!(call.await.is_err());
        assert!(matches!(
            profile.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        drop(profile);
        let restored = f.prepare().await?;
        assert!(matches!(
            restored.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        assert_eq!(f.observed.refreshes.load(Ordering::SeqCst), 1);
        let record: Value = serde_json::from_slice(&tokio::fs::read(&f.token).await?)?;
        assert_eq!(record["uncertain"], true);
        assert!(record["token"].is_null());
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn logout_rejects_late_login_and_callback_substitution_before_post() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        let session = profile.oauth().ok_or("missing OAuth owner")?;
        for suffix in [
            "state=wrong&code=one-time-code",
            "state=a&state=b&code=one-time-code",
        ] {
            let attempt = session.start_authorization().await?;
            assert!(matches!(
                attempt
                    .finish(&format!("http://127.0.0.1:1455/callback?{suffix}"))
                    .await,
                Err(Error::Authentication)
            ));
        }
        let substituted = session.start_authorization().await?;
        let url = oauth2::url::Url::parse(substituted.authorization_url())?;
        let parameters: BTreeMap<_, _> = url.query_pairs().into_owned().collect();
        assert!(matches!(
            substituted
                .finish(&format!(
                    "http://127.0.0.1:1456/callback?code=one-time-code&state={}",
                    parameters["state"]
                ))
                .await,
            Err(Error::Authentication)
        ));
        let attempt = session.start_authorization().await?;
        let url = oauth2::url::Url::parse(attempt.authorization_url())?;
        let parameters: BTreeMap<_, _> = url.query_pairs().into_owned().collect();
        session.logout().await?;
        assert!(matches!(
            attempt
                .finish(&format!(
                    "http://127.0.0.1:1455/callback?code=one-time-code&state={}",
                    parameters["state"]
                ))
                .await,
            Err(Error::Authentication)
        ));
        assert_eq!(f.observed.grants.load(Ordering::SeqCst), 0);
        drop(profile);
        assert!(matches!(
            f.prepare()
                .await?
                .complete(&messages(), &Options::default())
                .await,
            Err(Error::Authentication)
        ));
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn denied_refresh_and_scope_expansion_never_send_to_model() -> TestResult {
    timeout(WATCHDOG, async {
        for broad_scope in [false, true] {
            let f = Fixture::new().await?;
            let profile = f.prepare().await?;
            f.login(&profile).await?;
            drop(profile);
            f.expire().await?;
            f.observed
                .deny_refresh
                .store(!broad_scope, Ordering::SeqCst);
            f.observed.broad_scope.store(broad_scope, Ordering::SeqCst);
            let profile = f.prepare().await?;
            let error = profile
                .complete(&messages(), &Options::default())
                .await
                .err()
                .ok_or("unexpected model call")?;
            assert!(matches!(error, Error::Authentication));
            assert!(!format!("{error:?} {error}").contains("secret"));
            assert!(matches!(
                profile.complete(&messages(), &Options::default()).await,
                Err(Error::Authentication)
            ));
            assert_eq!(f.observed.refreshes.load(Ordering::SeqCst), 1);
            assert!(
                !f.observed
                    .requests
                    .lock()
                    .await
                    .iter()
                    .any(|r| r.0.starts_with("post /model "))
            );
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn device_pending_then_authorized_uses_provider_interval() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        let attempt = profile
            .oauth()
            .ok_or("missing OAuth owner")?
            .start_device_authorization()
            .await?;
        assert_eq!(attempt.user_code(), "LOGIN");
        assert_eq!(attempt.verification_uri(), format!("{}/verify", f.issuer));
        attempt.finish().await?;
        profile.complete(&messages(), &Options::default()).await?;
        assert_eq!(f.observed.polls.load(Ordering::SeqCst), 2);
        let times = f.observed.poll_times.lock().await;
        assert!(times[1].duration_since(times[0]) >= Duration::from_secs(1));
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn token_redirect_does_not_forward_the_authorization_code() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        f.observed.redirect_token.store(true, Ordering::SeqCst);
        let error = f
            .login(&profile)
            .await
            .err()
            .ok_or("redirected token grant succeeded")?;
        assert!(!error.to_string().contains("one-time-code"));
        assert!(matches!(
            profile.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        let requests = f.observed.requests.lock().await;
        assert_eq!(requests.len(), 1);
        assert!(!requests.iter().any(|r| r.0.contains("/stolen")));
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn device_denial_expiry_and_slow_down_cannot_activate_credentials() -> TestResult {
    timeout(WATCHDOG, async {
        for mode in [1, 2, 3] {
            let f = Fixture::new().await?;
            let profile = f.prepare().await?;
            f.observed.device_error.store(mode, Ordering::SeqCst);
            let attempt = profile
                .oauth()
                .ok_or("missing OAuth owner")?
                .start_device_authorization()
                .await?;
            assert!(matches!(attempt.finish().await, Err(Error::Authentication)));
            assert!(matches!(
                profile.complete(&messages(), &Options::default()).await,
                Err(Error::Authentication)
            ));
            assert_eq!(f.observed.polls.load(Ordering::SeqCst), 1);
            assert!(
                !f.observed
                    .requests
                    .lock()
                    .await
                    .iter()
                    .any(|r| r.0.starts_with("post /model "))
            );
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn persisted_tokens_cannot_move_to_another_destination_or_scope() -> TestResult {
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        f.login(&profile).await?;
        drop(profile);
        let original = tokio::fs::read_to_string(&f.config).await?;
        for changed in [
            original.replace("/model", "/other-model"),
            original.replace("[\"read\"]", "[\"admin\"]"),
        ] {
            tokio::fs::write(&f.config, changed).await?;
            assert!(matches!(f.prepare().await, Err(Error::Configuration)));
        }
        tokio::fs::write(&f.config, original).await?;
        let mut record: Value = serde_json::from_slice(&tokio::fs::read(&f.token).await?)?;
        record["token"]["scopes"] = json!(["admin"]);
        tokio::fs::write(&f.token, serde_json::to_vec(&record)?).await?;
        assert!(matches!(f.prepare().await, Err(Error::Configuration)));
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn warmed_turns_reuse_the_pool_under_concurrency() -> TestResult {
    use super::read_request;
    use std::time::Instant;
    use weaver_llm::TurnEvent;

    const WORKERS: usize = 4;
    const SAMPLES: usize = 32;
    const BODY: &str = concat!(
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\n",
        "data: [DONE]\n\n",
    );

    timeout(WATCHDOG, async {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let fixture = Fixture::with_model_endpoint(Some(format!("http://{}/model", listener.local_addr()?))).await?;
        let profile = Arc::new(fixture.prepare().await?);
        fixture.login(&profile).await?;
        let server = tokio::spawn(async move {
            let mut connections = JoinSet::new();
            let warmup = std::sync::Arc::new(tokio::sync::Barrier::new(WORKERS));
            for _ in 0..WORKERS {
                let (socket, _) = listener.accept().await?;
                socket.set_nodelay(true)?;
                let warmup = warmup.clone();
                connections.spawn(async move {
                    let mut socket = BufReader::new(socket);
                    let reply = format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\n\r\n{BODY}", BODY.len());
                    let mut served = 0;
                    while !socket.fill_buf().await?.is_empty() {
                        let (headers, request) = read_request(&mut socket).await?;
                        assert!(headers.contains("authorization: bearer snake-oil-access\r\n"));
                        assert_eq!(request["model"], "configured");
                        assert_eq!(request["stream"], true);
                        if served == 0 {
                            warmup.wait().await;
                        }
                        socket.get_mut().write_all(reply.as_bytes()).await?;
                        served += 1;
                    }
                    Ok::<_, io::Error>(served)
                });
            }
            let mut served = 0;
            while let Some(result) = connections.join_next().await {
                served += result??;
            }
            Ok::<_, Box<dyn std::error::Error + Send + Sync>>(served)
        });

        let mut callers = JoinSet::new();
        for _ in 0..WORKERS {
            let profile = profile.clone();
            callers.spawn(async move {
                let messages = messages();
                let options = Options::default();
                let mut timings = Vec::with_capacity(SAMPLES);
                for index in 0..=SAMPLES {
                    let start = Instant::now();
                    let mut turn = profile.stream_turn(&messages, &options).await?;
                    let headers = start.elapsed();
                    assert_eq!(turn.next_event().await?, Some(TurnEvent::Text("OK".into())));
                    let first = start.elapsed();
                    assert!(matches!(
                        turn.next_event().await?,
                        Some(TurnEvent::Finished { .. })
                    ));
                    assert!(turn.next_event().await?.is_none());
                    if index > 0 {
                        timings.push((headers, first, start.elapsed()));
                    }
                }
                Ok::<_, Error>(timings)
            });
        }
        let mut timings = Vec::with_capacity(WORKERS * SAMPLES);
        while let Some(result) = callers.join_next().await {
            timings.extend(result??);
        }
        assert_eq!(fixture.observed.grants.load(Ordering::SeqCst), 1);
        assert_eq!(fixture.observed.refreshes.load(Ordering::SeqCst), 0);
        assert_eq!(fixture.observed.requests.lock().await.len(), 1);
        profile.oauth().ok_or("missing credential owner")?.shutdown().await;
        drop(profile);
        let served = tokio::time::timeout(Duration::from_secs(2), server)
            .await??
            .map_err(io::Error::other)?;
        assert_eq!(served, WORKERS * (SAMPLES + 1));
        assert_eq!(timings.len(), WORKERS * SAMPLES);
        for (label, mut values) in [
            (
                "response headers",
                timings.iter().map(|sample| sample.0).collect::<Vec<_>>(),
            ),
            (
                "first event",
                timings.iter().map(|sample| sample.1).collect::<Vec<_>>(),
            ),
            (
                "complete turn",
                timings.iter().map(|sample| sample.2).collect::<Vec<_>>(),
            ),
            (
                "first event to terminal",
                timings
                    .iter()
                    .map(|sample| sample.2 - sample.1)
                    .collect::<Vec<_>>(),
            ),
        ] {
            values.sort_unstable();
            let rank = |percent: usize| values[(values.len() * percent).div_ceil(100) - 1];
            println!("{}", json!({
                "phase": label,
                "callers": WORKERS,
                "samples": values.len(),
                "p50_us": rank(50).as_secs_f64() * 1_000_000.0,
                "p99_us": rank(99).as_secs_f64() * 1_000_000.0,
            }));
        }
        Ok(())
    }).await?
}
