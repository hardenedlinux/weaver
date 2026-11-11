// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Fixture, TestResult, WATCHDOG, attempt, fixture, keys};
use serde_json::{Value, json};
use std::{
    sync::atomic::Ordering,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::{
    net::TcpListener,
    task::JoinSet,
    time::{Duration, timeout},
};
use weaver_llm::{Configuration, Error, oauth::OAuthSession};

const RESOURCE: &str = "https://gateway.example/";

async fn setup(authenticated: bool, actor: bool) -> TestResult<Fixture> {
    let f = fixture(false).await?;
    f.observed
        .exchange_authenticated
        .store(authenticated, Ordering::SeqCst);
    f.observed.exchange_actor.store(actor, Ordering::SeqCst);
    let mut extra = String::new();
    if authenticated {
        extra.push_str("\n[profiles.local.exchange.client_secret]\nfile = \"client-secret\"\n");
    }
    if actor {
        extra.push_str(&format!("\n[profiles.local.exchange.actor]\ntoken_type = \"urn:ietf:params:oauth:token-type:jwt\"\nexpires_at = {}\n[profiles.local.exchange.actor.token]\nfile = \"actor\"\n",SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs()+600));
    }
    for (name, value) in [
        ("client-secret", "exchange secret+:"),
        ("actor", "actor-safe-token"),
    ] {
        let path = f._directory.path().join(name);
        tokio::fs::write(&path, value).await?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).await?;
        }
    }
    tokio::fs::write(
        &f.config,
        format!(
            r#"
[profiles.local]
kind = "delegated"
endpoint = "{RESOURCE}"
timeout_ms = 1000
[profiles.local.identity]
issuer = "{issuer}"
client_id = "oaiapp-fixture"
redirect_uri = "http://127.0.0.1:1455/callback"
resource = "{issuer}/v1"
scopes = ["openid", "profile", "model.invoke"]
token_file = "auth/account.json"
login_timeout_ms = 2000
[profiles.local.exchange]
token_url = "{issuer}/exchange"
client_id = "exchange:client"
audience = "weaver"
scopes = ["provider:execute"]
{extra}
"#,
            issuer = f.issuer
        ),
    )
    .await?;
    Ok(f)
}

async fn prepare(f: &Fixture) -> Result<OAuthSession, Error> {
    Configuration::load(&f.config)
        .await?
        .prepare_delegation("local")
        .await
}

async fn login(f: &Fixture, owner: &OAuthSession) -> TestResult {
    let (attempt, callback) = attempt(f, owner).await?;
    attempt.finish(callback.as_str()).await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn oidc_exchange_is_shared_bound_persisted_and_separate_from_operation_identity() -> TestResult
{
    keys()?;
    timeout(WATCHDOG, async {
        let f = setup(false, false).await?;
        let owner = prepare(&f).await?;
        login(&f, &owner).await?;
        let mut tasks = JoinSet::new();
        for _ in 0..4 {
            let owner = owner.clone();
            tasks.spawn(async move { owner.delegated_credential(RESOURCE).await });
        }
        let mut digests = Vec::new();
        while let Some(result) = tasks.join_next().await {
            let credential = result??;
            assert_eq!(credential.resource(), RESOURCE);
            assert!(credential.bearer_header()?.is_sensitive());
            assert!(!format!("{credential:?}").contains("delegated-token"));
            digests.push(credential.token_sha256());
        }
        assert!(digests.iter().all(|d| d == &digests[0]));
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        let metadata = f.observed.metadata_reads.load(Ordering::SeqCst);
        owner.delegated_credential(RESOURCE).await?;
        assert_eq!(f.observed.metadata_reads.load(Ordering::SeqCst), metadata);
        assert!(matches!(
            owner
                .delegated_credential("https://substituted.invalid")
                .await,
            Err(Error::Configuration)
        ));
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        drop(owner);
        let restored = prepare(&f).await?;
        restored.delegated_credential(RESOURCE).await?;
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.tokens.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.model.load(Ordering::SeqCst), 0);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn basic_client_auth_and_actor_clip_the_child_lifetime() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = setup(true, true).await?;
        let owner = prepare(&f).await?;
        login(&f, &owner).await?;
        let credential = owner.delegated_credential(RESOURCE).await?;
        let record: Value = serde_json::from_slice(&tokio::fs::read(&f.token).await?)?;
        assert!(credential.expires_at() <= record["token"]["expires_at"].as_u64().ok_or("expiry")?);
        assert!(
            credential.expires_at()
                <= SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() + 600
        );
        let disk = serde_json::to_string(&record)?;
        assert!(!disk.contains("actor-safe-token"));
        assert!(!disk.contains("exchange secret"));
        drop(owner);
        tokio::fs::write(f._directory.path().join("actor"), "rotated-actor").await?;
        assert!(matches!(prepare(&f).await, Err(Error::Configuration)));
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unknown_exchange_cannot_replay_after_cancellation_or_restart() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = setup(false, false).await?;
        let owner = prepare(&f).await?;
        login(&f, &owner).await?;
        f.observed.exchange_block.store(true, Ordering::SeqCst);
        let owned = owner.clone();
        let task = tokio::spawn(async move { owned.delegated_credential(RESOURCE).await });
        f.observed.exchange_arrived.notified().await;
        task.abort();
        assert!(task.await.is_err());
        drop(owner);
        f.observed.exchange_block.store(false, Ordering::SeqCst);
        f.observed.exchange_release.notify_one();
        let restored = prepare(&f).await?;
        assert!(matches!(
            restored.delegated_credential(RESOURCE).await,
            Err(Error::Authentication)
        ));
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        login(&f, &restored).await?;
        restored.delegated_credential(RESOURCE).await?;
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 2);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn malformed_or_reflected_exchange_results_remain_unknown_without_retry() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        for fault in 1..=13 {
            let f = setup(false, true).await?;
            let owner = prepare(&f).await?;
            login(&f, &owner).await?;
            f.observed.exchange_fault.store(fault, Ordering::SeqCst);
            let error = owner
                .delegated_credential(RESOURCE)
                .await
                .expect_err("reject invalid result");
            assert!(!error.to_string().contains("must-not-escape"));
            assert!(!error.to_string().contains("actor-safe-token"));
            drop(owner);
            let restored = prepare(&f).await?;
            assert!(matches!(
                restored.delegated_credential(RESOURCE).await,
                Err(Error::Authentication)
            ));
            assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn known_child_expiry_can_renew_but_logout_fences_later_acquisition() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = setup(false, false).await?;
        let owner = prepare(&f).await?;
        login(&f, &owner).await?;
        owner.delegated_credential(RESOURCE).await?;
        drop(owner);
        let mut record: Value = serde_json::from_slice(&tokio::fs::read(&f.token).await?)?;
        record["token"]["issued_at"] = json!(1);
        record["delegation"]["issued_at"] = json!(1);
        record["delegation"]["expires_at"] = json!(2);
        tokio::fs::write(&f.token, serde_json::to_vec(&record)?).await?;
        let owner = prepare(&f).await?;
        owner.delegated_credential(RESOURCE).await?;
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 2);
        owner.logout().await?;
        assert!(matches!(
            owner.delegated_credential(RESOURCE).await,
            Err(Error::Authentication)
        ));
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 2);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn exchange_redirect_does_not_forward_subject_or_actor_credentials() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = setup(true, true).await?;
        let owner = prepare(&f).await?;
        login(&f, &owner).await?;
        let target = TcpListener::bind("127.0.0.1:0").await?;
        *f.observed.exchange_redirect.lock().await =
            Some(format!("http://{}/steal", target.local_addr()?));
        assert!(owner.delegated_credential(RESOURCE).await.is_err());
        assert!(
            timeout(Duration::from_millis(50), target.accept())
                .await
                .is_err()
        );
        assert_eq!(f.observed.exchanges.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}
