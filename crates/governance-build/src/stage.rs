//! Pinned Gerbil compiler helper preparation and explicit graph staging input.
use gerbil_scheme_aot_build::{gerbil_command, run_native_process, source_workspace};
/// Construct compiler input from explicit UTF-8 paths. This is build-time only.
/// No path comes from a runtime RPC or grants producer authority.
pub fn staging_expression(
    source: &std::path::Path,
    library: &std::path::Path,
    stage: &std::path::Path,
    application: &crate::ProgramApplication,
) -> Result<String, &'static str> {
    let source = source.to_str().ok_or("source path encoding")?;
    let library = library.to_str().ok_or("library path encoding")?;
    let stage = stage.to_str().ok_or("stage path encoding")?;
    if [source, library, stage].iter().any(|v| v.contains('\0')) {
        return Err("path contains NUL");
    }
    let application_source = application
        .source()
        .to_str()
        .ok_or("application path encoding")?;
    if application_source.contains('\0') {
        return Err("application path contains NUL");
    }
    let module = application.module();
    Ok(format!(
        "(import :gerbil/compiler :gerbil/expander :gerbil-scheme-rust/scheme/program-build) (compile-module {source:?} [output-dir: {library:?} invoke-gsc: #t optimize: #t static: #t]) (compile-module {application_source:?} [output-dir: {library:?} invoke-gsc: #f optimize: #t static: #t]) (unless (equal? (symbol->string (expander-context-id (import-module {application_source:?}))) {module:?}) (error \"approved application root mismatch\")) (gerbil-rs-stage-program {application_source:?} {stage:?} '(:gerbil/expander :hardenedlinux/weaver/scheme/governance/interface :hardenedlinux/weaver/scheme/policy/interface :hardenedlinux/weaver/scheme/gateway/interface))"
    ))
}
// Pin native runtime/UTF-8 modules and loaded compiler helper ABI together. An installed prefix may
// contain an older same-named helper with a different argument contract.
pub(crate) fn prepare_gerbil_modules(compiler: &std::ffi::OsStr, library: &std::path::Path) {
    let gerbil_source = source_workspace();
    for name in ["utf8", "runtime", "program-metadata", "program-build"] {
        let source = gerbil_source.join("scheme").join(format!("{name}.ss"));
        println!("cargo:rerun-if-changed={}", source.display());
        let expression = format!(
            "(import :gerbil/compiler) (compile-module {:?} [output-dir: {:?} invoke-gsc: #t optimize: #t static: #t])",
            source.to_str().expect("Gerbil source"),
            library.to_str().expect("isolated library")
        );
        run_native_process(
            gerbil_command(compiler).args(["-e", &expression]),
            "pinned Gerbil compiler helper",
            true,
        )
        .expect("pinned helper build");
    }
}
