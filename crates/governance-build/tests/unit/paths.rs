use crate::staging_expression;
use std::path::Path;
#[test]
fn staging_owns_static_output_and_quotes_paths_without_shell_execution() {
    let expression = staging_expression(
        Path::new("/tmp/a b/fixture.ss"),
        Path::new("/tmp/lib\"quoted"),
        Path::new("/tmp/stage"),
        &crate::ProgramApplication::approved(
            "operator/gateway/application",
            Path::new("/tmp/approved/application.ss"),
        )
        .expect("application"),
    )
    .expect("paths");
    assert!(expression.contains("output-dir: \"/tmp/lib\\\"quoted\""));
    assert!(expression.contains("/tmp/a b/fixture.ss"));
    assert!(expression.contains("invoke-gsc: #t"));
    assert!(!expression.contains("compile-file"));
    assert!(
        staging_expression(
            Path::new("bad\0path"),
            Path::new("lib"),
            Path::new("stage"),
            &crate::ProgramApplication::approved(
                "operator/gateway/application",
                Path::new("/tmp/approved/application.ss")
            )
            .expect("application")
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
    let text = staging_expression(
        Path::new("entry.ss"),
        Path::new("lib"),
        Path::new("stage"),
        &app,
    )
    .expect("expression");
    assert!(text.contains("/tmp/approved/application.ss"));
    assert!(text.contains("expander-context-id (import-module"));
    assert!(text.contains("approved application root mismatch"));
    assert!(!text.contains("t/fixtures"));
}
