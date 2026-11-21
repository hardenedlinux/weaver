// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use std::path::Path;
#[test]
fn a_matching_module_name_does_not_select_another_sources_package_product() {
    let package = Path::new("/tmp/weaver");
    for (source, expected) in [
        ("/tmp/weaver/scheme/gateway/provider-program.ss", true),
        ("/tmp/operator/provider-program.ss", false),
    ] {
        let app = crate::ProgramApplication::approved(
            "hardenedlinux/weaver/scheme/gateway/provider-program",
            Path::new(source),
        )
        .expect("explicit application");
        let request = crate::ProgramStageRequest::new(
            package,
            Path::new("/tmp/prefix/lib"),
            Path::new("/tmp/output"),
            &app,
        )
        .expect("native inputs");
        assert_eq!(crate::tooling::package_application(&request), expected);
    }
}
#[test]
fn archive_stage_arguments_preserve_data_and_reject_invalid_paths() {
    let app = crate::ProgramApplication::approved(
        "operator/application",
        Path::new("/tmp/a \"quoted λ/application.ss"),
    )
    .expect("application");
    let request = crate::ProgramStageRequest::new(
        Path::new("/tmp/package"),
        Path::new("/tmp/prefix/lib"),
        Path::new("/tmp/output"),
        &app,
    )
    .expect("native arguments");
    assert_eq!(
        request.application_source,
        "/tmp/a \"quoted λ/application.ss"
    );
    assert_eq!(request.library, "/tmp/prefix/lib");
    for package in ["relative", "/tmp/bad\0path"] {
        assert!(
            crate::ProgramStageRequest::new(
                Path::new(package),
                Path::new("/tmp/prefix/lib"),
                Path::new("/tmp/output"),
                &app
            )
            .is_err()
        );
    }
    assert!(
        crate::ProgramStageRequest::new(
            Path::new("/tmp/package"),
            Path::new("/tmp/not-lib"),
            Path::new("/tmp/output"),
            &app
        )
        .is_err()
    );
}

#[test]
fn application_names_cannot_inject_source_or_select_weaver_fixtures() {
    assert!(crate::ProgramApplication::qualification(Path::new("/tmp/root"), "release").is_err());
    assert!(crate::ProgramApplication::qualification(Path::new("/tmp/root"), "debug").is_ok());
    for module in [
        "",
        ":operator/app",
        "operator//app",
        "operator/../app",
        "operator/app) (exit)",
        "operator/app\n",
        "operator/app\0",
        "hardenedlinux/weaver/scheme/gateway/qualification-program",
        "hardenedlinux/weaver/t/fixtures/governance-program",
    ] {
        assert!(
            crate::ProgramApplication::approved(module, Path::new("/tmp/approved/application.ss"))
                .is_err()
        );
    }
    let app = crate::ProgramApplication::approved(
        "operator/gateway/application",
        Path::new("/tmp/approved/application.ss"),
    )
    .expect("application");
    assert_eq!(app.module(), "operator/gateway/application");
    assert!(
        app.forbidden_modules()
            .contains(&crate::application::QUALIFICATION_APPLICATION)
    );
    let request = crate::ProgramStageRequest::new(
        Path::new("/tmp/package"),
        Path::new("/tmp/prefix/lib"),
        Path::new("/tmp/stage"),
        &app,
    )
    .expect("native request");
    assert_eq!(request.application_source, "/tmp/approved/application.ss");
    assert_eq!(request.application_module, app.module());
}
