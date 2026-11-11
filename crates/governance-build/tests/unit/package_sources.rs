// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::tooling::bind_package_sources;
use std::{
    fs,
    time::{SystemTime, UNIX_EPOCH},
};

#[test]
fn native_package_inputs_follow_the_selected_store_without_overwriting_sources() {
    let root = std::env::temp_dir().join(format!(
        "weaver-package-sources-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos()
    ));
    let input = root.join("input");
    let next = root.join("next");
    let output = root.join("output");
    for path in [
        input.join("lib"),
        input.join("pkg/github.com/lab/modules"),
        next.join("lib"),
        next.join("pkg/github.com/lab/modules"),
        output.clone(),
    ] {
        fs::create_dir_all(path).expect("fixture directories");
    }
    let leaf = "github.com/lab/modules/governance";
    fs::write(input.join("pkg").join(leaf), "original source").expect("input");
    fs::write(next.join("pkg").join(leaf), "next source").expect("next");
    // Native gxpkg may already have created an empty package directory.
    fs::create_dir(output.join("pkg")).expect("empty native store");
    bind_package_sources(&input.join("lib"), &output).expect("borrow input");
    bind_package_sources(&input.join("lib"), &output).expect("same input");
    assert_eq!(
        fs::read_to_string(output.join("pkg").join(leaf)).expect("native path"),
        "original source"
    );
    bind_package_sources(&next.join("lib"), &output).expect("new build owner");
    assert_eq!(
        fs::read_to_string(output.join("pkg").join(leaf)).expect("new path"),
        "next source"
    );
    assert_eq!(
        fs::read_to_string(input.join("pkg").join(leaf)).expect("old input retained"),
        "original source"
    );
    fs::rename(next.join("pkg"), next.join("retired-pkg")).expect("retire input store");
    bind_package_sources(&input.join("lib"), &output).expect("replace dangling output link");
    assert_eq!(
        fs::read_to_string(output.join("pkg").join(leaf)).expect("rebound path"),
        "original source"
    );
    assert_eq!(
        fs::read_to_string(next.join("retired-pkg").join(leaf)).expect("retired store retained"),
        "next source"
    );
    fs::remove_file(output.join("pkg")).expect("remove owned link");
    fs::create_dir(output.join("pkg")).expect("occupied directory");
    fs::write(output.join("pkg/keep"), "keep").expect("sentinel");
    assert!(bind_package_sources(&input.join("lib"), &output).is_err());
    assert_eq!(
        fs::read_to_string(output.join("pkg/keep")).expect("sentinel survives"),
        "keep"
    );
    assert!(bind_package_sources(&root.join("missing/lib"), &output).is_err());
    assert!(bind_package_sources(&output.join("lib"), &output).is_err());
    fs::remove_dir_all(root).expect("fixture cleanup");
}
