//! Pure request preparation is inert; only the guarded owner invokes send.
use reqwest::blocking::{Client, Request, Response};
use weaver_contracts::{Error, Result};

pub(super) struct PreparedRequest {
    client: Client,
    request: Request,
}
impl PreparedRequest {
    pub(super) fn new(client: Client, request: Request) -> Self {
        Self { client, request }
    }
    /// Returns on response headers, not on a request-write completion receipt.
    /// The SDK owns its IO driver; body exhaustion is not a sealed writer.
    pub(super) fn wait_for_response_headers(self) -> Result<Response> {
        self.client
            .execute(self.request)
            .map_err(|_| Error::Conflict("provider outcome unknown"))
    }
}
pub(super) fn validate(response: Response) -> Result<Response> {
    if response.status() != 200
        || response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_none_or(|v| v.split(';').next().map(str::trim) != Some("text/event-stream"))
    {
        return Err(Error::Conflict(
            "provider did not return an admitted SSE stream",
        ));
    }
    Ok(response)
}
