// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{
    Ledger,
    persistence::commit_observer::{Cut, Decision, Observer},
    provider_oauth,
};
use ring::signature::{Ed25519KeyPair, KeyPair};
use std::sync::Arc;
use weaver_contracts::{
    ProviderOAuthDeployment, ProviderOAuthGrant, ProviderOAuthUse, SourceIdentity, body_digest,
};

struct Fault(Cut);

impl Observer for Fault {
    fn observe(&self, cut: Cut) -> Decision {
        if cut != self.0 {
            Decision::Continue
        } else if cut == Cut::BeforeCommit {
            Decision::Rollback
        } else {
            Decision::LoseAcknowledgment
        }
    }
}

#[test]
fn oauth_witness_survives_both_uncertain_native_commit_cuts() {
    for cut in [Cut::BeforeCommit, Cut::AfterCommit] {
        let db_dir = tempfile::tempdir().expect("database directory");
        let independent = tempfile::tempdir().expect("witness directory");
        let witness = independent.path().join("authority.log");
        std::fs::File::create_new(&witness).expect("provision witness");
        let signer = Ed25519KeyPair::from_seed_unchecked(&[9; 32]).expect("issuer");
        let relay = body_digest("relay certificate");
        let config = ProviderOAuthDeployment {
            issuer: "issuer".into(),
            subject: "subject".into(),
            client: "client".into(),
            audience: "resource".into(),
            public_key: hex::encode(signer.public_key().as_ref()),
            relay_certificate_sha256: Some(relay.clone()),
            witness_file: Some(witness.display().to_string()),
        };
        let identity = SourceIdentity {
            certificate_sha256: body_digest("source-cert"),
            credential_sha256: body_digest("source-credential"),
            public_key_sha256: body_digest("source-key"),
        };
        let path = db_dir.path().join("ledger.db");
        let mut ledger = Ledger::open(&path).expect("ledger");
        ledger
            .configure_provider_oauth(Some(&config))
            .expect("genesis");
        let ingress = body_digest("ingress certificate");
        let digest = body_digest("original");
        let leaf_digest = body_digest("leaf");
        let now = provider_oauth::now().expect("clock");
        let mut root = ProviderOAuthGrant {
            issuer: config.issuer.clone(),
            subject: config.subject.clone(),
            client: config.client.clone(),
            audience: config.audience.clone(),
            scopes: vec!["provider:execute".into()],
            token_hash: digest.clone(),
            certificate_sha256: ingress.clone(),
            not_before: now - 1,
            expires_at: now + 60,
            signature: String::new(),
            parent_token_hash: None,
            issuer_epoch: 0,
        };
        let mut leaf = ProviderOAuthGrant {
            token_hash: leaf_digest.clone(),
            certificate_sha256: relay.clone(),
            parent_token_hash: Some(digest.clone()),
            ..root.clone()
        };
        for grant in [&mut root, &mut leaf] {
            let message =
                hex::decode(grant.signing_digest().expect("grant digest")).expect("digest");
            grant.signature = hex::encode(signer.sign(&message).as_ref());
            ledger
                .with_authenticated_source(&identity, |ledger| ledger.publish_provider_oauth(grant))
                .expect("publish signed grant");
        }
        let evidence = ProviderOAuthUse {
            token_hash: leaf_digest,
            certificate_sha256: relay,
            ingress_certificate_sha256: Some(ingress),
        };
        let prepared = ledger
            .connection
            .prepare_provider_oauth(Some(&evidence), "provider:execute")
            .expect("prepare grant before revoke");
        {
            let scope = crate::persistence::begin(&mut ledger.connection).expect("original scope");
            assert_eq!(
                scope
                    .check_provider_oauth(prepared.as_ref())
                    .expect("current"),
                Some(now + 60)
            );
        }
        ledger.observe_provider_commit(Arc::new(Fault(cut)));
        assert!(
            ledger
                .with_authenticated_source(&identity, |ledger| ledger
                    .revoke_provider_oauth(&digest))
                .is_err()
        );
        assert!(
            ledger.close().is_err(),
            "uncertain session cannot attest a clean close"
        );
        let mut ledger = Ledger::open(&path).expect("reopen ledger");
        assert_eq!(
            provider_oauth::revoked(&ledger.connection, &digest).expect("native state"),
            cut == Cut::AfterCommit
        );
        {
            let scope = crate::persistence::begin(&mut ledger.connection).expect("recovered scope");
            assert!(
                scope.check_provider_oauth(prepared.as_ref()).is_err(),
                "a cached candidate cannot bypass a witness ahead of the database or a committed tombstone"
            );
        }
        ledger
            .configure_provider_oauth(Some(&config))
            .expect("replay anchored decision");
        {
            let scope =
                crate::persistence::begin(&mut ledger.connection).expect("reconciled scope");
            assert!(
                scope.check_provider_oauth(prepared.as_ref()).is_err(),
                "a cached candidate cannot bypass the recovered tombstone"
            );
        }
        assert!(
            provider_oauth::revoked(&ledger.connection, &digest).expect("recovered revocation")
        );
        let before = std::fs::read(&witness).expect("retained journal");
        ledger
            .with_authenticated_source(&identity, |ledger| ledger.revoke_provider_oauth(&digest))
            .expect("exact retry");
        assert_eq!(
            std::fs::read(&witness).expect("journal after retry"),
            before
        );
    }
}

#[test]
fn oauth_witness_activation_retains_existing_direct_tombstones() {
    let db = tempfile::tempdir().expect("database directory");
    let authority = tempfile::tempdir().expect("witness directory");
    let journal = authority.path().join("authority.log");
    std::fs::File::create_new(&journal).expect("provision journal");
    let mut ledger = Ledger::open(db.path().join("original.db")).expect("original store");
    let direct = ProviderOAuthDeployment {
        issuer: "issuer".into(),
        subject: "subject".into(),
        client: "client".into(),
        audience: "resource".into(),
        public_key: "ab".repeat(32),
        relay_certificate_sha256: None,
        witness_file: None,
    };
    let identity = SourceIdentity {
        certificate_sha256: body_digest("source-cert"),
        credential_sha256: body_digest("source-credential"),
        public_key_sha256: body_digest("source-key"),
    };
    ledger
        .configure_provider_oauth(Some(&direct))
        .expect("direct deployment");
    let hash = body_digest("revoked before activation");
    ledger
        .with_authenticated_source(&identity, |ledger| ledger.revoke_provider_oauth(&hash))
        .expect("direct revocation");
    let protected = ProviderOAuthDeployment {
        witness_file: Some(journal.display().to_string()),
        ..direct.clone()
    };
    ledger
        .configure_provider_oauth(Some(&protected))
        .expect("one-way activation");
    assert!(ledger.configure_provider_oauth(Some(&direct)).is_err());
    ledger.close().expect("close original");
    let mut restored = Ledger::open(db.path().join("restored.db")).expect("restored projection");
    restored
        .configure_provider_oauth(Some(&protected))
        .expect("witness recovery");
    assert!(provider_oauth::revoked(&restored.connection, &hash).expect("seed retained"));
}
