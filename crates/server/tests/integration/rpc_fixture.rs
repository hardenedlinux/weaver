//! Test-only mTLS identities and typed unary calls; no provider egress.
use rcgen::{
    BasicConstraints, CertificateParams, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyPair,
    KeyUsagePurpose,
};
use tonic::transport::{Certificate, Channel, ClientTlsConfig, Endpoint, Identity};
pub struct Leaf {
    pub pem: String,
    pub key: String,
    pub der: Vec<u8>,
}
pub struct Pki {
    pub ca: String,
    pub server: Leaf,
    pub source: Leaf,
    pub operation: Leaf,
    pub next: Leaf,
}
fn leaf(issuer: &Issuer<'_, KeyPair>, usage: ExtendedKeyUsagePurpose) -> Leaf {
    let mut params = CertificateParams::new(vec!["localhost".into()]).expect("SAN");
    params.extended_key_usages.push(usage);
    params.key_usages.push(KeyUsagePurpose::DigitalSignature);
    let key = KeyPair::generate().expect("key");
    let certificate = params.signed_by(&key, issuer).expect("certificate");
    Leaf {
        pem: certificate.pem(),
        key: key.serialize_pem(),
        der: certificate.der().to_vec(),
    }
}
pub fn pki() -> Pki {
    let mut params = CertificateParams::new(vec![]).expect("CA");
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![
        KeyUsagePurpose::KeyCertSign,
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::CrlSign,
    ];
    let key = KeyPair::generate().expect("CA key");
    let ca = params.self_signed(&key).expect("CA certificate");
    let issuer = Issuer::new(params, key);
    Pki {
        ca: ca.pem(),
        server: leaf(&issuer, ExtendedKeyUsagePurpose::ServerAuth),
        source: leaf(&issuer, ExtendedKeyUsagePurpose::ClientAuth),
        operation: leaf(&issuer, ExtendedKeyUsagePurpose::ClientAuth),
        next: leaf(&issuer, ExtendedKeyUsagePurpose::ClientAuth),
    }
}
pub async fn connect(address: std::net::SocketAddr, peer: &Leaf, ca: &str) -> Channel {
    Endpoint::from_shared(format!("https://{address}"))
        .expect("endpoint")
        .connect_timeout(std::time::Duration::from_secs(3))
        .timeout(std::time::Duration::from_secs(10))
        .tls_config(
            ClientTlsConfig::new()
                .domain_name("localhost")
                .ca_certificate(Certificate::from_pem(ca))
                .identity(Identity::from_pem(&peer.pem, &peer.key)),
        )
        .expect("TLS")
        .connect()
        .await
        .expect("mTLS channel")
}
pub async fn unary<I, O>(
    channel: Channel,
    token: &str,
    path: &'static str,
    input: I,
) -> Result<O, tonic::Status>
where
    I: prost::Message + Default + Send + Sync + 'static,
    O: prost::Message + Default + Send + Sync + 'static,
{
    let mut grpc = tonic::client::Grpc::new(channel);
    grpc.ready()
        .await
        .map_err(|_| tonic::Status::unavailable("test channel unavailable"))?;
    let mut request = tonic::Request::new(input);
    request.metadata_mut().insert(
        "authorization",
        format!("Bearer {token}").parse().expect("credential"),
    );
    let response = grpc
        .unary(
            request,
            tonic::codegen::http::uri::PathAndQuery::from_static(path),
            tonic_prost::ProstCodec::<I, O>::default(),
        )
        .await?;
    Ok(response.into_inner())
}
