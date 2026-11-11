// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Shared local signed-token issuer; no model or Gateway authorization is simulated here.

use super::TestResult;
use base64::Engine;
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use rsa::{RsaPrivateKey, pkcs1::EncodeRsaPrivateKey, traits::PublicKeyParts};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    sync::{Mutex, Notify},
    task::{JoinHandle, JoinSet},
};

pub(crate) struct Keys {
    signing: EncodingKey,
    jwks: Value,
}

pub(crate) fn keys() -> TestResult<&'static Keys> {
    static KEYS: OnceLock<Result<Keys, String>> = OnceLock::new();
    KEYS.get_or_init(|| {
        let private = RsaPrivateKey::new(&mut rand::rngs::OsRng, 2048).map_err(|_| "RSA fixture generation")?;
        let der = private.to_pkcs1_der().map_err(|_| "RSA fixture encoding")?;
        let encode = &base64::engine::general_purpose::URL_SAFE_NO_PAD;
        Ok(Keys { signing: EncodingKey::from_rsa_der(der.as_bytes()),
            jwks: json!({"keys":[{"kty":"RSA","kid":"fixture","alg":"RS256","use":"sig",
                "n":encode.encode(private.n().to_bytes_be()),"e":encode.encode(private.e().to_bytes_be())}]}) })
    }).as_ref().map_err(|error| std::io::Error::other(error.clone()).into())
}

#[derive(Default)]
pub(crate) struct Observed {
    pub nonce: Mutex<String>,
    pub challenge: Mutex<String>,
    pub client_id: Mutex<String>,
    pub subject: Mutex<String>,
    pub minted: Mutex<BTreeMap<String, String>>,
    pub metadata_reads: AtomicUsize,
    pub key_reads: AtomicUsize,
    pub response_delay_ms: AtomicUsize,
    pub fault: AtomicUsize,
    pub tokens: AtomicUsize,
    pub refreshes: AtomicUsize,
    pub model: AtomicUsize,
    pub revocations: AtomicUsize,
    pub invalid_grant: AtomicBool,
    pub revoke_failure: AtomicBool,
    pub forms: Mutex<Vec<BTreeMap<String, String>>>,
    pub registered: AtomicBool,
    pub exchanges: AtomicUsize,
    pub exchange_fault: AtomicUsize,
    pub exchange_block: AtomicBool,
    pub exchange_authenticated: AtomicBool,
    pub exchange_actor: AtomicBool,
    pub exchange_arrived: Notify,
    pub exchange_release: Notify,
    pub exchange_resource: Mutex<String>,
    pub exchange_redirect: Mutex<Option<String>>,
}

pub(crate) async fn spawn() -> TestResult<(String, Arc<Observed>, JoinHandle<()>)> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let issuer = format!("http://{}", listener.local_addr()?);
    let observed = Arc::new(Observed::default());
    *observed.client_id.lock().await = "oaiapp-fixture".into();
    *observed.subject.lock().await = "account-A".into();
    let observed_task = observed.clone();
    let issuer_task = issuer.clone();
    let server = tokio::spawn(async move {
        let mut tasks = JoinSet::new();
        loop {
            tokio::select! {
                connection = listener.accept() => {
                let Ok((socket,_)) = connection else { break; };
                let observed = observed_task.clone();
                let issuer = issuer_task.clone();
                tasks.spawn(async move { let _ = handle(socket, &issuer, observed).await; });
                }
                _ = tasks.join_next(), if !tasks.is_empty() => {}
            }
        }
    });
    Ok((issuer, observed, server))
}

async fn handle(socket: TcpStream, issuer: &str, observed: Arc<Observed>) -> TestResult {
    let mut socket = BufReader::new(socket);
    let mut header = String::new();
    let mut length = 0usize;
    loop {
        let mut line = String::new();
        if socket.read_line(&mut line).await? == 0 {
            return Err("short fixture request".into());
        }
        if line == "\r\n" {
            break;
        }
        if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            length = value.trim().parse()?;
        }
        header.push_str(&line);
        if header.len() > 16384 {
            return Err("oversized fixture header".into());
        }
    }
    if length > 32768 {
        return Err("oversized fixture body".into());
    }
    let mut body = vec![0; length];
    socket.read_exact(&mut body).await?;
    let form: BTreeMap<String, String> = oauth2::url::form_urlencoded::parse(&body)
        .into_owned()
        .collect();
    let mut status = "200 OK";
    let mut content_type = "application/json";
    let mut extra_headers = String::new();
    let response = if header.starts_with("GET /.well-known/openid-configuration ") {
        observed.metadata_reads.fetch_add(1, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(
            observed.response_delay_ms.load(Ordering::SeqCst) as u64,
        ))
        .await;
        json!({"issuer":if observed.fault.load(Ordering::SeqCst)==12 {"https://wrong.invalid"} else {issuer},
            "jwks_uri":format!("{issuer}/keys"),"revocation_endpoint":format!("{issuer}/revoke"),
            "authorization_endpoint":format!("{issuer}/api/accounts/authorize"),
            "token_endpoint":match observed.fault.load(Ordering::SeqCst) {
                14 => json!("http://steal.invalid/token"),15 => Value::Null,
                _ => json!(format!("{issuer}/api/accounts/oauth/token"))
            }}).to_string()
    } else if header.starts_with("GET /keys ") {
        observed.key_reads.fetch_add(1, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(
            observed.response_delay_ms.load(Ordering::SeqCst) as u64,
        ))
        .await;
        let mut keys = keys()?.jwks.clone();
        if observed.fault.load(Ordering::SeqCst) == 13 {
            let first = keys["keys"][0].clone();
            keys["keys"]
                .as_array_mut()
                .ok_or("missing keys")?
                .push(first);
        }
        keys.to_string()
    } else if header.starts_with("POST /api/accounts/oauth/token ") {
        observed.forms.lock().await.push(form.clone());
        observed.tokens.fetch_add(1, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(
            observed.response_delay_ms.load(Ordering::SeqCst) as u64,
        ))
        .await;
        let issued = observed.client_id.lock().await.clone();
        assert_eq!(form["client_id"], issued);
        assert_eq!(form["resource"], format!("{issuer}/v1"));
        if form["grant_type"] == "refresh_token" {
            let previous = observed.refreshes.fetch_add(1, Ordering::SeqCst);
            assert_eq!(
                form["refresh_token"],
                format!("refresh-{issued}-{previous}")
            );
        } else {
            assert_eq!(form["grant_type"], "authorization_code");
            assert_eq!(form["redirect_uri"], "http://127.0.0.1:1455/callback");
            use sha2::{Digest, Sha256};
            let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD
                .encode(Sha256::digest(form["code_verifier"].as_bytes()));
            assert_eq!(challenge, *observed.challenge.lock().await);
        }
        if observed.invalid_grant.load(Ordering::SeqCst) {
            status = "400 Bad Request";
            json!({"error":"invalid_grant","error_description":"private-token-detail"}).to_string()
        } else {
            token(issuer, &observed).await?
        }
    } else if header.starts_with("POST /exchange ") {
        let (code, body, redirect) = exchange_reply(&header, &form, &observed).await?;
        status = code;
        if let Some(target) = redirect {
            extra_headers = format!("Location: {target}\r\n");
        }
        body
    } else if header.starts_with("POST /revoke ") {
        observed.revocations.fetch_add(1, Ordering::SeqCst);
        let issued = observed.client_id.lock().await.clone();
        assert_eq!(form["client_id"], issued);
        assert_eq!(form["token_type_hint"], "refresh_token");
        assert_eq!(
            form["token"],
            format!(
                "refresh-{issued}-{}",
                observed.refreshes.load(Ordering::SeqCst)
            )
        );
        if observed.revoke_failure.load(Ordering::SeqCst) {
            status = "503 Service Unavailable";
        }
        String::new()
    } else if header.starts_with("POST /v1/responses ") {
        observed.model.fetch_add(1, Ordering::SeqCst);
        let normalized = header.to_ascii_lowercase();
        assert!(
            observed
                .minted
                .lock()
                .await
                .values()
                .any(|token| normalized.contains(&format!("authorization: bearer {token}\r\n")))
        );
        let response = json!({"id":"response","model":"configured","status":"completed","output":[
            {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi"}]}]});
        let request: Value = serde_json::from_slice(&body)?;
        if request["stream"] == true {
            content_type = "text/event-stream";
            format!(
                "data: {{\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}}\n\ndata: {}\n\n",
                json!({"type":"response.completed","response":response})
            )
        } else {
            response.to_string()
        }
    } else {
        return Err("unknown fixture request".into());
    };
    socket.get_mut().write_all(format!("HTTP/1.1 {status}\r\n{extra_headers}Content-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{response}", response.len()).as_bytes()).await?;
    Ok(())
}

async fn exchange_reply(
    header: &str,
    form: &BTreeMap<String, String>,
    o: &Observed,
) -> TestResult<(&'static str, String, Option<String>)> {
    assert_eq!(
        form["grant_type"],
        "urn:ietf:params:oauth:grant-type:token-exchange"
    );
    assert_eq!(
        form["subject_token_type"],
        "urn:ietf:params:oauth:token-type:access_token"
    );
    assert_eq!(form["requested_token_type"], form["subject_token_type"]);
    assert_eq!(form["scope"], "provider:execute");
    assert_eq!(form["audience"], "weaver");
    let configured = o.exchange_resource.lock().await.clone();
    assert_eq!(
        form["resource"],
        if configured.is_empty() {
            "https://gateway.example/"
        } else {
            &configured
        }
    );
    assert!(
        o.minted
            .lock()
            .await
            .values()
            .any(|value| value == &form["subject_token"])
    );
    if o.exchange_authenticated.load(Ordering::SeqCst) {
        let expected = base64::engine::general_purpose::STANDARD
            .encode("exchange%3Aclient:exchange+secret%2B%3A");
        let authorization = header
            .lines()
            .filter_map(|s| s.split_once(':'))
            .find(|(key, _)| key.eq_ignore_ascii_case("authorization"))
            .ok_or("missing client authentication")?
            .1
            .trim();
        assert_eq!(authorization, format!("Basic {expected}"));
        assert!(!form.contains_key("client_id"));
    } else {
        assert_eq!(form["client_id"], "exchange:client");
    }
    if o.exchange_actor.load(Ordering::SeqCst) {
        assert_eq!(form["actor_token"], "actor-safe-token");
        assert_eq!(
            form["actor_token_type"],
            "urn:ietf:params:oauth:token-type:jwt"
        );
    } else {
        assert!(!form.contains_key("actor_token"));
    }
    let n = o.exchanges.fetch_add(1, Ordering::SeqCst) + 1;
    if o.exchange_block.load(Ordering::SeqCst) {
        o.exchange_arrived.notify_one();
        o.exchange_release.notified().await;
    }
    if let Some(target) = o.exchange_redirect.lock().await.clone() {
        return Ok(("307 Temporary Redirect", "{}".into(), Some(target)));
    }
    let mut response = json!({"access_token":format!("delegated-token-{n:040}"),"token_type":"Bearer",
        "issued_token_type":"urn:ietf:params:oauth:token-type:access_token","expires_in":7200,"scope":"provider:execute"});
    match o.exchange_fault.load(Ordering::SeqCst) {
        1 => response["issued_token_type"] = json!("urn:ietf:params:oauth:token-type:id_token"),
        2 => response["token_type"] = json!("N_A"),
        3 => {
            response
                .as_object_mut()
                .ok_or("object")?
                .remove("expires_in");
        }
        4 => response["scope"] = json!("provider:execute source:publish"),
        5 => response["scope"] = json!("different"),
        6 => response["expires_in"] = json!(0),
        7 => response["access_token"] = json!(form["subject_token"]),
        8 => response["refresh_token"] = json!("must-not-activate"),
        9 => {
            return Ok((
                "503 Service Unavailable",
                json!({"secret":"must-not-escape"}).to_string(),
                None,
            ));
        }
        10 => response["expires_in"] = json!(u64::MAX),
        11 => response["access_token"] = json!("x".repeat(70 * 1024)),
        12 => response["access_token"] = json!("actor-safe-token"),
        13 => response["access_token"] = json!("bad\r\nX-Injected: yes"),
        14 => {
            response.as_object_mut().ok_or("object")?.remove("scope");
        }
        _ => {}
    }
    Ok(("200 OK", response.to_string(), None))
}

async fn token(issuer: &str, observed: &Observed) -> TestResult<String> {
    let fault = observed.fault.load(Ordering::SeqCst);
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let issued = observed.client_id.lock().await.clone();
    let subject = observed.subject.lock().await.clone();
    let mut claims = json!({"iss":issuer,"aud":issued,"sub":subject,
        "iat":now,"exp":now+3600,"nonce":observed.nonce.lock().await.clone(),
        "email":"same@example.invalid"});
    match fault {
        1 => claims["iss"] = json!("https://wrong.invalid"),
        2 => claims["aud"] = json!("oaiapp-other"),
        3 => claims["nonce"] = json!("wrong-nonce"),
        4 => {
            claims["exp"] = json!(now - 1);
            claims["iat"] = json!(now - 3600);
        }
        6 => claims["sub"] = json!("account-B"),
        _ => {}
    }
    let mut header = Header::new(if fault == 10 {
        Algorithm::HS256
    } else {
        Algorithm::RS256
    });
    header.kid = Some(if fault == 9 { "unknown" } else { "fixture" }.into());
    let signing = if fault == 10 {
        EncodingKey::from_secret(b"fake-key")
    } else {
        keys()?.signing.clone()
    };
    let mut id = encode(&header, &claims, &signing)?;
    if fault == 5 {
        let offset = id.rfind('.').ok_or("missing signature")? + 1;
        let mut bytes = id.into_bytes();
        bytes[offset] = if bytes[offset] == b'A' { b'B' } else { b'A' };
        id = String::from_utf8(bytes)?;
    }
    let rotation = observed.refreshes.load(Ordering::SeqCst);
    let access = format!("access-{issued}-{rotation}");
    observed
        .minted
        .lock()
        .await
        .insert(issued.clone(), access.clone());
    Ok(
        json!({"access_token":access,"refresh_token":format!("refresh-{issued}-{rotation}"),
        "token_type":"Bearer","expires_in":3600,
        "scope":if fault==7 {"openid profile email offline_access"}
            else if observed.registered.load(Ordering::SeqCst) {"openid profile model.invoke"}
            else {"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"},
        "id_token":if fault==8 {Value::Null} else {json!(id)}})
        .to_string(),
    )
}
