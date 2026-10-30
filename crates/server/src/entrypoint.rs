//! Deployment runtime construction; the binary adapter retains process exit handling.

/// Run the deployment service with the default Tokio runtime and its normal drain.
#[tokio::main]
pub async fn run() -> weaver_contracts::Result<()> {
    crate::run_from_env().await
}
