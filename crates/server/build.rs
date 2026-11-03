// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=../../proto/gateway/v1/gateway.proto");
    tonic_prost_build::configure()
        .build_client(false)
        .compile_protos(&["../../proto/gateway/v1/gateway.proto"], &["../../proto"])?;
    Ok(())
}
