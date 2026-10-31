//! Deployment entrypoint; runtime composition belongs to the server library.
#![forbid(unsafe_code)]
fn main() {
    eprintln!(
        "weaver startup stage=process-main clock={:?}",
        std::time::SystemTime::now()
    );
    if let Err(error) = weaver_server::entrypoint::run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
