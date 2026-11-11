// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{
    TestResult, messages,
    oauth_issuer::{Observed, keys},
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    path::PathBuf,
    sync::{Arc, atomic::Ordering},
    time::Duration,
};
use tokio::{
    sync::Mutex,
    task::{JoinHandle, JoinSet},
    time::timeout,
};
use weaver_llm::{Configuration, Error, Options, PreparedProfile, oauth::AuthorizationAttempt};

const WATCHDOG: Duration = Duration::from_secs(5);

struct Fixture {
    _directory: tempfile::TempDir,
    config: PathBuf,
    token: PathBuf,
    issuer: String,
    observed: Arc<Observed>,
    server: JoinHandle<()>,
    host: Mutex<Option<String>>,
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
        let token = directory.path().join("auth/account.json");
        let (issuer, observed, server) = super::oauth_issuer::spawn().await?;
        tokio::fs::write(
            &config,
            format!(
                r#"
[profiles.local]
kind = "direct"
protocol = "openai-responses"
endpoint = "{issuer}/v1/responses"
model = "configured"
timeout_ms = 1000
max_response_bytes = 4096
[profiles.local.credential.openai]
agent_name = "Weaver Snake Oil"
issuer = "{issuer}"
resource = "{issuer}/v1"
redirect_uri = "http://127.0.0.1:1455/callback"
token_file = "auth/account.json"
host_id_file = "auth/host.json"
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
            observed,
            server,
            host: Mutex::new(None),
        })
    }

    async fn prepare(&self) -> Result<PreparedProfile, Error> {
        Configuration::load(&self.config)
            .await?
            .prepare("local")
            .await
    }

    async fn attempt(
        &self,
        profile: &PreparedProfile,
        returning: bool,
    ) -> TestResult<(AuthorizationAttempt, oauth2::url::Url)> {
        let attempt = profile
            .oauth()
            .ok_or("missing owner")?
            .start_authorization()
            .await?;
        let url = oauth2::url::Url::parse(attempt.authorization_url())?;
        assert_eq!(url.path(), "/api/accounts/authorize");
        let parameters: BTreeMap<_, _> = url.query_pairs().into_owned().collect();
        let issued = self.observed.client_id.lock().await.clone();
        assert_eq!(
            parameters["client_id"],
            if returning {
                issued.as_str()
            } else {
                "dynamic_agent_client"
            }
        );
        assert_eq!(parameters["resource"], format!("{}/v1", self.issuer));
        assert_eq!(parameters["code_challenge_method"], "S256");
        assert_eq!(parameters.contains_key("agent_name_hint"), !returning);
        *self.observed.nonce.lock().await = parameters["nonce"].clone();
        *self.observed.challenge.lock().await = parameters["code_challenge"].clone();
        let mut host = self.host.lock().await;
        if let Some(expected) = host.as_ref() {
            assert_eq!(&parameters["ext_agent_host_id"], expected);
        } else {
            let id = parameters["ext_agent_host_id"]
                .strip_prefix("urn:uuid:")
                .ok_or("host UUID")?;
            assert_eq!(uuid::Uuid::parse_str(id)?.get_version_num(), 4);
            *host = Some(parameters["ext_agent_host_id"].clone());
        }
        let mut callback = oauth2::url::Url::parse("http://127.0.0.1:1455/callback")?;
        callback
            .query_pairs_mut()
            .append_pair("state", &parameters["state"])
            .append_pair("code", "one-time-code");
        if !returning {
            callback.query_pairs_mut().append_pair("client_id", &issued);
        }
        Ok((attempt, callback))
    }

    async fn login(&self, profile: &PreparedProfile, returning: bool) -> TestResult {
        let (attempt, callback) = self.attempt(profile, returning).await?;
        attempt.finish(callback.as_str()).await?;
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

#[path = "oidc.rs"]
mod oidc;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dynamic_registration_restart_refresh_and_logout_use_the_issued_client() -> TestResult {
    keys()?; // Cryptographic fixture preparation precedes the runtime watchdog.
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        f.login(&profile, false).await?;
        let account = profile
            .oauth()
            .ok_or("missing owner")?
            .account_identity()
            .await
            .ok_or("missing identity")?;
        assert_eq!(account.client_id(), "oaiapp-fixture");
        assert_eq!(account.subject(), "account-A");
        profile.complete(&messages(), &Options::default()).await?;
        let mut stream = profile
            .stream_turn(&messages(), &Options::default())
            .await?;
        let mut text = String::new();
        let mut finished = false;
        while let Some(event) = stream.next_event().await? {
            match event {
                weaver_llm::TurnEvent::Text(delta) => text.push_str(&delta),
                weaver_llm::TurnEvent::Finished { .. } => finished = true,
            }
        }
        assert_eq!(text, "Hi");
        assert!(finished);
        assert_eq!(f.observed.metadata_reads.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.key_reads.load(Ordering::SeqCst), 1);
        assert_eq!(f.observed.tokens.load(Ordering::SeqCst), 1);
        drop(profile);
        f.expire().await?;
        let restored = Arc::new(f.prepare().await?);
        let mut callers = JoinSet::new();
        for _ in 0..4 {
            let profile = restored.clone();
            callers.spawn(async move { profile.complete(&messages(), &Options::default()).await });
        }
        while let Some(result) = callers.join_next().await {
            result??;
        }
        assert_eq!(f.observed.refreshes.load(Ordering::SeqCst), 1);
        f.login(&restored, true).await?;
        let owner = restored.oauth().ok_or("missing owner")?;
        owner.logout().await?;
        assert_eq!(f.observed.revocations.load(Ordering::SeqCst), 1);
        assert!(matches!(
            restored.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
        assert_eq!(
            owner
                .account_identity()
                .await
                .ok_or("lost registration")?
                .client_id(),
            "oaiapp-fixture"
        );
        owner.shutdown().await;
        drop(restored);
        let restored = f.prepare().await?;
        f.login(&restored, true).await?;
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn invalid_identity_and_missing_inference_permission_never_activate() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        for fault in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13] {
            let f = Fixture::new().await?;
            let profile = f.prepare().await?;
            f.login(&profile, false).await?;
            f.observed.fault.store(fault, Ordering::SeqCst);
            let error = f
                .login(&profile, true)
                .await
                .err()
                .ok_or("invalid identity activated")?;
            assert!(!error.to_string().contains("private-token-detail"));
            assert!(matches!(
                profile.complete(&messages(), &Options::default()).await,
                Err(Error::Authentication)
            ));
            assert_eq!(f.observed.model.load(Ordering::SeqCst), 0);
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn missing_and_substituted_callback_client_ids_are_rejected_before_post() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        let (attempt, callback) = f.attempt(&profile, false).await?;
        let mut missing = callback.clone();
        let values: Vec<_> = missing
            .query_pairs()
            .into_owned()
            .filter(|(key, _)| key != "client_id")
            .collect();
        missing.query_pairs_mut().clear().extend_pairs(values);
        assert!(matches!(
            attempt.finish(missing.as_str()).await,
            Err(Error::Authentication)
        ));
        assert_eq!(f.observed.tokens.load(Ordering::SeqCst), 0);
        f.login(&profile, false).await?;
        let (attempt, mut callback) = f.attempt(&profile, true).await?;
        callback
            .query_pairs_mut()
            .append_pair("client_id", "oaiapp-other");
        assert!(matches!(
            attempt.finish(callback.as_str()).await,
            Err(Error::Authentication)
        ));
        assert_eq!(f.observed.tokens.load(Ordering::SeqCst), 1);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn invalid_grant_retains_the_issued_registration_for_new_login() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        f.observed.invalid_grant.store(true, Ordering::SeqCst);
        assert!(f.login(&profile, false).await.is_err());
        assert!(
            profile
                .oauth()
                .ok_or("missing owner")?
                .account_identity()
                .await
                .is_none()
        );
        drop(profile);
        let profile = f.prepare().await?;
        f.observed.invalid_grant.store(false, Ordering::SeqCst);
        f.login(&profile, true).await?;
        assert_eq!(f.observed.tokens.load(Ordering::SeqCst), 2);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unconfirmed_remote_revocation_still_clears_local_tokens() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        f.login(&profile, false).await?;
        f.observed.revoke_failure.store(true, Ordering::SeqCst);
        assert!(matches!(
            profile.oauth().ok_or("missing owner")?.logout().await,
            Err(Error::RevocationUnconfirmed)
        ));
        assert_eq!(f.observed.revocations.load(Ordering::SeqCst), 3);
        assert!(matches!(
            profile.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
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
async fn separate_accounts_share_a_host_without_sharing_registration_or_tokens() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let first = f.prepare().await?;
        f.login(&first, false).await?;
        let original = tokio::fs::read_to_string(&f.config).await?;
        let second = original
            .replace("profiles.local", "profiles.second")
            .replace("auth/account.json", "auth/second.json");
        tokio::fs::write(&f.config, format!("{original}\n{second}")).await?;
        *f.observed.client_id.lock().await = "oaiapp-second".into();
        *f.observed.subject.lock().await = "account-B".into();
        let second = Configuration::load(&f.config)
            .await?
            .prepare("second")
            .await?;
        f.login(&second, false).await?;
        let one = first
            .oauth()
            .ok_or("missing owner")?
            .account_identity()
            .await
            .ok_or("missing account")?;
        let two = second
            .oauth()
            .ok_or("missing owner")?
            .account_identity()
            .await
            .ok_or("missing account")?;
        assert_eq!(one.subject(), "account-A");
        assert_eq!(two.subject(), "account-B");
        assert_ne!(one.client_id(), two.client_id());
        assert_eq!(one.email(), two.email());
        first.complete(&messages(), &Options::default()).await?;
        second.complete(&messages(), &Options::default()).await?;
        drop(first);
        drop(second);
        let other_file = f.token.with_file_name("second.json");
        tokio::fs::write(&other_file, tokio::fs::read(&f.token).await?).await?;
        assert!(matches!(
            Configuration::load(&f.config)
                .await?
                .prepare("second")
                .await,
            Err(Error::Configuration)
        ));
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resource_and_protocol_substitution_fail_before_credential_preparation() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let original = tokio::fs::read_to_string(&f.config).await?;
        for document in [
            original.replace("openai-responses", "anthropic-messages"),
            original.replace("/v1/responses", "/v12/responses"),
            original.replace(
                &format!("resource = \"{}/v1\"", f.issuer),
                "resource = \"https://other.invalid/v1\"",
            ),
        ] {
            tokio::fs::write(&f.config, document).await?;
            assert!(matches!(f.prepare().await, Err(Error::Configuration)));
        }
        assert_eq!(f.observed.tokens.load(Ordering::SeqCst), 0);
        assert!(!tokio::fs::try_exists(&f.token).await?);
        tokio::fs::write(&f.config, original).await?;
        let profile = f.prepare().await?;
        f.login(&profile, false).await?;
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn login_deadline_includes_discovery_and_identity_verification() -> TestResult {
    keys()?;
    timeout(WATCHDOG, async {
        let f = Fixture::new().await?;
        let profile = f.prepare().await?;
        f.login(&profile, false).await?;
        f.observed.response_delay_ms.store(750, Ordering::SeqCst);
        assert!(f.login(&profile, true).await.is_err());
        assert_eq!(f.observed.tokens.load(Ordering::SeqCst), 2);
        assert_eq!(f.observed.metadata_reads.load(Ordering::SeqCst), 2);
        assert_eq!(f.observed.key_reads.load(Ordering::SeqCst), 2);
        assert!(matches!(
            profile.complete(&messages(), &Options::default()).await,
            Err(Error::Authentication)
        ));
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
