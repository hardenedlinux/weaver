// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One-shot source publication using the existing authenticated owner.
use crate::{
    grpc_config::{read_path, required},
    pb,
};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
use tonic::{
    Code, Request, Status,
    metadata::{Ascii, MetadataValue},
    service::{Interceptor, interceptor::InterceptedService},
    transport::{Certificate, Channel, ClientTlsConfig, Endpoint, Identity},
};
use weaver_contracts::{Error, Result};

pub(crate) type Client = pb::gateway_client::GatewayClient<InterceptedService<Channel, Bearer>>;

#[derive(Clone)]
pub(crate) struct Bearer(MetadataValue<Ascii>);

impl Interceptor for Bearer {
    fn call(&mut self, mut request: Request<()>) -> std::result::Result<Request<()>, Status> {
        request
            .metadata_mut()
            .insert("authorization", self.0.clone());
        Ok(request)
    }
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct PreparationFile {
    source: SourceConnection,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SourceConnection {
    pub(crate) producer: Option<String>,
    pub(crate) file: Option<PathBuf>,
    address: String,
    server_name: String,
    ca: PathBuf,
    certificate: PathBuf,
    key: PathBuf,
    token_env: String,
}

enum SourceInput {
    Producer(String),
    File(Box<crate::source_file::FileSource>),
}

impl SourceConnection {
    fn load(config: Option<&Path>) -> Result<Self> {
        match config {
            Some(path) => {
                let bytes = read_path(path)?;
                let text = std::str::from_utf8(&bytes)
                    .map_err(|_| Error::Invalid("weaver.toml encoding"))?;
                let mut source = toml::from_str::<PreparationFile>(text)
                    .map_err(|_| Error::Invalid("weaver.toml source configuration"))?
                    .source;
                source.resolve_paths(path)?;
                Ok(source)
            }
            None => Ok(Self {
                producer: std::env::var_os("WEAVER_CONTROL_PRODUCER")
                    .map(|name| {
                        name.into_string()
                            .map_err(|_| Error::Invalid("source producer encoding"))
                    })
                    .transpose()?,
                file: std::env::var_os("WEAVER_CONTROL_CONFIG").map(PathBuf::from),
                address: required("WEAVER_CONTROL_AUTHORITY_SOURCE_ADDRESS")?,
                server_name: required("WEAVER_CONTROL_AUTHORITY_SERVER_NAME")?,
                ca: required("WEAVER_CONTROL_AUTHORITY_CA")?.into(),
                certificate: required("WEAVER_CONTROL_AUTHORITY_SOURCE_CERT")?.into(),
                key: required("WEAVER_CONTROL_AUTHORITY_SOURCE_KEY")?.into(),
                token_env: "WEAVER_CONTROL_AUTHORITY_SOURCE_TOKEN".into(),
            }),
        }
    }
}

impl SourceConnection {
    pub(crate) fn resolve_paths(&mut self, path: &Path) -> Result<()> {
        let directory = path
            .parent()
            .ok_or(Error::Invalid("weaver.toml directory"))?;
        self.ca = directory.join(&self.ca);
        self.certificate = directory.join(&self.certificate);
        self.key = directory.join(&self.key);
        if let Some(file) = &mut self.file {
            *file = directory.join(&file);
        }
        Ok(())
    }
}

pub(crate) async fn connect(settings: &SourceConnection) -> Result<Client> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let secret = required(&settings.token_env)?;
    if secret.is_empty() {
        return Err(Error::Invalid("source bearer"));
    }
    let mut token: MetadataValue<Ascii> = format!("Bearer {secret}")
        .parse()
        .map_err(|_| Error::Invalid("source bearer"))?;
    token.set_sensitive(true);
    let tls = ClientTlsConfig::new()
        .domain_name(&settings.server_name)
        .ca_certificate(Certificate::from_pem(read_path(&settings.ca)?))
        .identity(Identity::from_pem(
            read_path(&settings.certificate)?,
            read_path(&settings.key)?,
        ));
    let channel = Endpoint::from_shared(format!("https://{}", settings.address))
        .and_then(|endpoint| endpoint.timeout(Duration::from_secs(10)).tls_config(tls))
        .map_err(|_| Error::Invalid("source listener configuration"))?
        .connect()
        .await
        .map_err(|_| Error::Conflict("source listener unavailable"))?;
    Ok(
        pb::gateway_client::GatewayClient::with_interceptor(channel, Bearer(token))
            .max_decoding_message_size(4 * 1024 * 1024)
            .max_encoding_message_size(2 * 1024 * 1024),
    )
}

async fn compile(client: &mut Client, producer: String) -> Result<pb::SourceCompositionRequest> {
    let reply = client
        .compile_source(pb::ProducerRequest {
            producer: producer.clone(),
        })
        .await
        .map_err(|_| Error::Conflict("approved source compilation failed"))?
        .into_inner();
    let authority = client
        .inspect_source_authority(pb::Empty {})
        .await
        .map_err(|_| Error::Conflict("source authority observation failed"))?
        .into_inner();
    if reply.producer != producer || reply.authority.as_ref() != Some(&authority) {
        return Err(Error::Conflict("compiled source authority changed"));
    }
    Ok(pb::SourceCompositionRequest {
        source: reply.artifact,
        ..Default::default()
    })
}

fn verify_receipt(
    receipt: pb::PublicationReceipt,
    key: &pb::PublicationKey,
    publication: &weaver_contracts::Publication,
) -> Result<()> {
    let revision = match publication.expected_revision {
        Some(parent) => parent
            .checked_add(1)
            .filter(|next| *next <= weaver_contracts::MAX_CREDITS)
            .ok_or(Error::Invalid("source activation revision"))?,
        None => 0,
    };
    if receipt.operation_id != key.operation_id
        || receipt.digest != key.digest
        || receipt.outcome != pb::PublicationOutcome::Committed as i32
        || receipt.revision != Some(revision)
        || receipt.fence != Some(publication.fence)
    {
        return Err(Error::Conflict("source activation receipt binding"));
    }
    Ok(())
}

fn validated_original(artifact: pb::SourceArtifact) -> Result<weaver_governance::OwnedSource> {
    let original = crate::source_composition::decode(pb::SourceCompositionRequest {
        source: Some(artifact),
        ..Default::default()
    })
    .map_err(|_| Error::Invalid("prepared source data"))?;
    weaver_governance::OwnedSource::from_source(original.source)
        .map_err(|_| Error::Invalid("prepared source binding"))
}

async fn compose(
    client: &mut Client,
    input: crate::source_file::FileSource,
) -> Result<pb::SourceCompositionRequest> {
    if input.select_on_request
        && (input.input.source.tasks.len() != 1
            || input.input.source.tasks[0].nodes.len() != 1
            || input.input.routing.len() != 1)
    {
        return Err(Error::Invalid("deferred source scope"));
    }
    let request = crate::source_artifact::composition(&input.input);
    let response = client
        .compose_source(request.clone())
        .await
        .map_err(|_| Error::Conflict("source bundle composition failed"))?
        .into_inner();
    let selected = response
        .artifact
        .ok_or(Error::Invalid("selected source missing"))?;
    if !response.catalog_version.is_empty()
        || validated_original(selected.clone())?.publication() != &input.input.source.publication
    {
        return Err(Error::Conflict("composed source publication changed"));
    }
    let scope = if input.select_on_request {
        request
    } else {
        pb::SourceCompositionRequest {
            source: Some(selected),
            ..Default::default()
        }
    };
    Ok(scope)
}

async fn publish(
    client: &mut Client,
    scope: pb::SourceCompositionRequest,
    publication: &weaver_contracts::Publication,
    review: Option<weaver_contracts::DeltaReview>,
) -> Result<()> {
    let wire = scope
        .source
        .as_ref()
        .and_then(|artifact| artifact.publication.clone())
        .ok_or(Error::Invalid("prepared source publication"))?;
    let key = pb::PublicationKey {
        operation_id: publication.operation_id.clone(),
        digest: publication.digest()?,
    };
    let committed = match client.inspect_publication(key.clone()).await {
        Ok(response) => {
            verify_receipt(response.into_inner(), &key, publication)?;
            true
        }
        Err(status) if status.code() == Code::NotFound => {
            let staged = client
                .stage_authority(wire.clone())
                .await
                .map_err(|_| Error::Conflict("source staging result unknown"))?
                .into_inner();
            if staged != key {
                return Err(Error::Conflict("source staging receipt binding"));
            }
            false
        }
        Err(_) => return Err(Error::Conflict("source publication observation failed")),
    };
    client
        .register_published_task(pb::RegisterPublishedTaskRequest {
            task: None,
            publication: Some(key.clone()),
            source_scope: Some(scope),
        })
        .await
        .map_err(|_| Error::Conflict("source registration result unknown"))?;
    if !committed {
        if let Some(review) = review {
            let expected_digest = review.review.digest()?;
            let registered = client
                .register_publication_review(crate::review_wire::evidence_message(review))
                .await
                .map_err(|_| Error::Conflict("source review registration result unknown"))?
                .into_inner();
            if registered.publication.as_ref() != Some(&key)
                || registered.review_digest != expected_digest
            {
                return Err(Error::Conflict("source review receipt binding"));
            }
        }
        let receipt = client
            .publish_authority(wire)
            .await
            .map_err(|_| Error::Conflict("source publication result unknown"))?
            .into_inner();
        verify_receipt(receipt, &key, publication)?;
    }
    Ok(())
}

pub(crate) async fn run(config: Option<&Path>) -> Result<()> {
    let mut settings = SourceConnection::load(config)?;
    let source = match (settings.producer.take(), settings.file.take()) {
        (Some(producer), None) => {
            weaver_contracts::identifier(&producer)?;
            SourceInput::Producer(producer)
        }
        (None, Some(path)) => SourceInput::File(Box::new(crate::source_file::load(&path)?)),
        _ => {
            return Err(Error::Invalid(
                "exactly one source producer or file required",
            ));
        }
    };
    let mut client = connect(&settings).await?;
    match source {
        SourceInput::Producer(producer) => {
            let scope = compile(&mut client, producer).await?;
            let original = validated_original(
                scope
                    .source
                    .clone()
                    .ok_or(Error::Invalid("compiled source missing"))?,
            )?;
            publish(&mut client, scope, original.publication(), None).await
        }
        SourceInput::File(input) => {
            let publication = input.input.source.publication.clone();
            let mut input = *input;
            let review = input.review.take();
            let scope = compose(&mut client, input).await?;
            publish(&mut client, scope, &publication, review).await
        }
    }
}
