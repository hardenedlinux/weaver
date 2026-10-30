fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=../../proto/gateway/v1/gateway.proto");
    tonic_prost_build::configure()
        .build_client(false)
        .compile_protos(&["../../proto/gateway/v1/gateway.proto"], &["../../proto"])?;
    Ok(())
}
