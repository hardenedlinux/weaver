// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Fixture, TestResult, WATCHDOG, keys, messages};
use std::{
    collections::BTreeMap,
    sync::{Arc, atomic::Ordering},
};
use tokio::{task::JoinSet, time::timeout};
use weaver_llm::{
    Error, Options, PreparedProfile,
    oauth::{AuthorizationAttempt, OAuthSession},
};

#[path = "token_exchange.rs"]
mod exchange;

async fn fixture(revoke: bool) -> TestResult<Fixture> {
    let f = Fixture::new().await?;
    f.observed.registered.store(true, Ordering::SeqCst);
    tokio::fs::write(
        &f.config,
        format!(
            r#"
[profiles.local]
kind = "direct"
protocol = "openai-responses"
endpoint = "{issuer}/v1/responses"
model = "configured"
timeout_ms = 1000
max_response_bytes = 4096
[profiles.local.credential.oidc]
issuer = "{issuer}"
client_id = "oaiapp-fixture"
redirect_uri = "http://127.0.0.1:1455/callback"
resource = "{issuer}/v1"
scopes = ["openid", "profile", "model.invoke"]
token_file = "auth/account.json"
login_timeout_ms = 2000
revoke_on_logout = {revoke}
"#,
            issuer = f.issuer
        ),
    )
    .await?;
    Ok(f)
}

async fn attempt(
    f: &Fixture,
    owner: &OAuthSession,
) -> TestResult<(AuthorizationAttempt, oauth2::url::Url)> {
    let attempt = owner.start_authorization().await?;
    let url = oauth2::url::Url::parse(attempt.authorization_url())?;
    let parameters: BTreeMap<_, _> = url.query_pairs().into_owned().collect();
    assert_eq!(parameters["client_id"], "oaiapp-fixture");
    assert_eq!(parameters["scope"], "openid profile model.invoke");
    assert_eq!(parameters["resource"], format!("{}/v1", f.issuer));
    assert_eq!(parameters["code_challenge_method"], "S256");
    assert!(!parameters.contains_key("ext_agent_host_id"));
    assert!(!parameters.contains_key("agent_name_hint"));
    *f.observed.nonce.lock().await = parameters["nonce"].clone();
    *f.observed.challenge.lock().await = parameters["code_challenge"].clone();
    let mut callback = oauth2::url::Url::parse("http://127.0.0.1:1455/callback")?;
    callback
        .query_pairs_mut()
        .append_pair("state", &parameters["state"])
        .append_pair("code", "one-time-code");
    Ok((attempt, callback))
}

async fn login(f: &Fixture, profile: &PreparedProfile) -> TestResult {
    let (attempt, callback) = attempt(f, profile.oauth().ok_or("missing owner")?).await?;
    attempt.finish(callback.as_str()).await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fixed_registration_reuses_discovery_owner_and_four_caller_refresh() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = fixture(false).await?;
        let p = f.prepare().await?;
        login(&f, &p).await?;
        let owner = p.oauth().ok_or("missing owner")?;
        let account = owner.account_identity().await.ok_or("missing account")?;
        assert_eq!(account.client_id(), "oaiapp-fixture");
        assert_eq!(account.subject(), "account-A");
        let metadata = f.observed.metadata_reads.load(Ordering::SeqCst);
        p.complete(&messages(), &Options::default()).await?;
        let mut stream = p.stream_turn(&messages(), &Options::default()).await?;
        while stream.next_event().await?.is_some() {}
        assert_eq!(f.observed.metadata_reads.load(Ordering::SeqCst), metadata);
        assert!(
            tokio::fs::metadata(f._directory.path().join("auth/host.json"))
                .await
                .is_err()
        );
        drop(p);
        f.expire().await?;
        let p = Arc::new(f.prepare().await?);
        let mut tasks = JoinSet::new();
        for _ in 0..4 {
            let p = p.clone();
            tasks.spawn(async move { p.complete(&messages(), &Options::default()).await });
        }
        while let Some(result) = tasks.join_next().await {
            result??;
        }
        assert_eq!(f.observed.refreshes.load(Ordering::SeqCst), 1);
        let (stale, callback) = attempt(&f, p.oauth().ok_or("missing owner")?).await?;
        p.oauth().ok_or("missing owner")?.logout().await?;
        assert!(matches!(
            stale.finish(callback.as_str()).await,
            Err(Error::Authentication)
        ));
        assert_eq!(f.observed.revocations.load(Ordering::SeqCst), 0);
        drop(p);
        let restored = f.prepare().await?;
        assert!(matches!(
            restored.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        let (new, _) = attempt(&f, restored.oauth().ok_or("missing owner")?).await?;
        let url = oauth2::url::Url::parse(new.authorization_url())?;
        assert!(!url.query_pairs().any(|(name, _)| name == "id_token_hint"));
        assert_eq!(f.observed.tokens.load(Ordering::SeqCst), 2);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn registered_identity_rejects_substituted_signed_claims_and_missing_permission() -> TestResult
{
    keys()?;
    timeout(WATCHDOG, async {
        for fault in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13] {
            let f = fixture(false).await?;
            let p = f.prepare().await?;
            login(&f, &p).await?;
            p.complete(&messages(), &Options::default()).await?;
            f.observed.fault.store(fault, Ordering::SeqCst);
            assert!(login(&f, &p).await.is_err());
            assert!(matches!(
                p.complete(&messages(), &Options::default()).await,
                Err(Error::Authentication)
            ));
            assert_eq!(f.observed.model.load(Ordering::SeqCst), 1);
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unsafe_discovery_is_rejected_before_grant_or_private_record() -> TestResult {
    timeout(WATCHDOG, async {
        for fault in [12, 14, 15] {
            let f = fixture(false).await?;
            f.observed.fault.store(fault, Ordering::SeqCst);
            assert!(f.prepare().await.is_err());
            assert_eq!(f.observed.tokens.load(Ordering::SeqCst), 0);
            assert_eq!(f.observed.key_reads.load(Ordering::SeqCst), 0);
            assert!(tokio::fs::metadata(&f.token).await.is_err());
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn registered_client_resource_and_protocol_cannot_rebind_persisted_identity() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = fixture(false).await?;
        let p = f.prepare().await?;
        login(&f, &p).await?;
        drop(p);
        let original = tokio::fs::read_to_string(&f.config).await?;
        for text in [
            original.replace("oaiapp-fixture", "another-client"),
            original.replace("/v1\"", "/v12\""),
            original.replace("openai-responses", "anthropic-messages"),
        ] {
            tokio::fs::write(&f.config, text).await?;
            assert!(matches!(f.prepare().await, Err(Error::Configuration)));
        }
        tokio::fs::write(&f.config, original).await?;
        let restored = f.prepare().await?;
        restored.complete(&messages(), &Options::default()).await?;
        assert_eq!(f.observed.tokens.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn optional_remote_revocation_never_restores_locally_cleared_credentials() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        for fail in [false, true] {
            let f = fixture(true).await?;
            let p = f.prepare().await?;
            login(&f, &p).await?;
            f.observed.revoke_failure.store(fail, Ordering::SeqCst);
            let result = p.oauth().ok_or("missing owner")?.logout().await;
            if fail {
                assert!(matches!(result, Err(Error::RevocationUnconfirmed)));
            } else {
                result?;
            }
            assert_eq!(
                f.observed.revocations.load(Ordering::SeqCst),
                if fail { 3 } else { 1 }
            );
            drop(p);
            let restored = f.prepare().await?;
            assert!(matches!(
                restored.complete(&messages(), &Options::default()).await,
                Err(Error::Authentication)
            ));
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}
