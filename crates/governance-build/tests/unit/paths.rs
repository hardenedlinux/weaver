use crate::staging_expression;
use std::path::Path;
#[test]
fn staging_owns_static_output_and_quotes_paths_without_shell_execution() {
    let expression = staging_expression(
        Path::new("/tmp/a b/fixture.ss"),
        Path::new("/tmp/lib\"quoted"),
        Path::new("/tmp/stage"),
    )
    .expect("paths");
    assert!(expression.contains("output-dir: \"/tmp/lib\\\"quoted\""));
    assert!(expression.contains("/tmp/a b/fixture.ss"));
    assert!(expression.contains("invoke-gsc: #f"));
    assert!(!expression.contains("compile-file"));
    assert!(
        staging_expression(Path::new("bad\0path"), Path::new("lib"), Path::new("stage")).is_err()
    );
}
