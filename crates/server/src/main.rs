//! Deployment entrypoint; runtime composition belongs to the server library.
#[tokio::main]
async fn main() {
    if let Err(error) = weaver_server::run_from_env().await {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
