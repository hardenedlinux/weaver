//! Test-only ABI binding to the compiler-owned graph and one approved export.
#![allow(unsafe_code)]
use gerbil_scheme::{GerbilRuntime, LinkedGerbilProgram, LinkedObjectExport};
unsafe extern "C" {
    fn ___LNK_weaver__governance__program(
        ctx: *mut gerbil_scheme_sys::GerbilGlobalState,
    ) -> *mut gerbil_scheme_sys::GerbilModuleOrLink;
    fn weaver_capture_source_v1(root: i64) -> i64;
    fn gerbil_scheme_instance_setup_diagnostic(out: *mut i64) -> i32;
}
/// Initialize this fixed graph once; initialization failure is terminal.
pub fn initialize() -> GerbilRuntime {
    let home = std::env::var_os("GERBIL_HOME")
        .expect("explicit approved GERBIL_HOME is required by the embedded module loader");
    assert!(
        std::path::Path::new(&home)
            .join("lib/gerbil/core.ssi")
            .is_file()
    );
    // SAFETY: compiler-owned graph
    // includes the pinned bridge and returning
    // initializer; its exact Gerbil linker signature and symbols have process life.
    let program = unsafe { LinkedGerbilProgram::from_linker(___LNK_weaver__governance__program) };
    eprintln!(
        "governance Gerbil capabilities={:?}",
        gerbil_scheme::VmCapabilities::linked()
    );
    GerbilRuntime::initialize_program(program).unwrap_or_else(|error| {
        let mut diagnostic = [0i64; 4];
        // SAFETY: Gerbil copies exactly four i64 values to this live local buffer.
        let status = unsafe { gerbil_scheme_instance_setup_diagnostic(diagnostic.as_mut_ptr()) };
        panic!("AA initialization: {error:?}; diagnostic={diagnostic:?} status={status}");
    })
}
/// Bind only the qualification producer; no arbitrary export address is accepted.
pub fn capture(runtime: &GerbilRuntime) -> LinkedObjectExport<'_> {
    // SAFETY: this compiled export catches exceptions, borrows one input root
    // and transfers a fresh strong result with no retained pointer or reentry.
    unsafe { runtime.bind_object_export(weaver_capture_source_v1) }.expect("source export")
}
