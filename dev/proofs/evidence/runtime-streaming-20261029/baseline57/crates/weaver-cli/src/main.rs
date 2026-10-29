//! Local owner entrypoint; not an authenticated network service.
fn main() {
    if let Err(e) = weaver_cli::run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
