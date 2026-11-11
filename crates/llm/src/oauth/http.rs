// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::Error;

pub(super) struct OAuthHttp {
    pub client: reqwest::Client,
    pub headers: reqwest::header::HeaderMap,
    pub github_token_url: Option<String>,
}

impl<'a> oauth2::AsyncHttpClient<'a> for OAuthHttp {
    type Error = Error;
    type Future = std::pin::Pin<
        Box<dyn std::future::Future<Output = Result<oauth2::HttpResponse, Error>> + Send + 'a>,
    >;

    fn call(&'a self, request: oauth2::HttpRequest) -> Self::Future {
        Box::pin(self.request(request))
    }
}

impl OAuthHttp {
    pub(super) async fn post_form(
        &self,
        url: &str,
        values: &[(&str, &str)],
    ) -> Result<oauth2::HttpResponse, Error> {
        let body = oauth2::url::form_urlencoded::Serializer::new(String::new())
            .extend_pairs(values.iter().copied())
            .finish()
            .into_bytes();
        let request = oauth2::http::Request::builder()
            .method("POST")
            .uri(url)
            .header("content-type", "application/x-www-form-urlencoded")
            .header("accept", "application/json")
            .body(body)
            .map_err(|_| Error::Authentication)?;
        self.request(request).await
    }

    pub(super) async fn get_json<T: serde::de::DeserializeOwned>(
        &self,
        url: &str,
    ) -> Result<T, Error> {
        let request = oauth2::http::Request::builder()
            .uri(url)
            .header("accept", "application/json")
            .body(Vec::new())
            .map_err(|_| Error::Authentication)?;
        let response = self.request(request).await?;
        if response.status() != oauth2::http::StatusCode::OK {
            return Err(Error::Authentication);
        }
        serde_json::from_slice(response.body()).map_err(|_| Error::Authentication)
    }

    pub(super) async fn request(
        &self,
        request: oauth2::HttpRequest,
    ) -> Result<oauth2::HttpResponse, Error> {
        let (parts, body) = request.into_parts();
        let github_poll = self.github_token_url.as_deref() == Some(parts.uri.to_string().as_str());
        let mut response = self
            .client
            .request(parts.method, parts.uri.to_string())
            .headers(self.headers.clone())
            .headers(parts.headers)
            .body(body)
            .send()
            .await
            .map_err(|_| Error::Authentication)?;
        let status = response.status();
        let mut result = oauth2::http::Response::builder().status(status);
        *result.headers_mut().ok_or(Error::Authentication)? = response.headers().clone();
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| Error::Authentication)? {
            if bytes.len().saturating_add(chunk.len()) > 64 * 1024 {
                return Err(Error::Authentication);
            }
            bytes.extend_from_slice(&chunk);
        }
        // GitHub device polling reports OAuth errors with HTTP 200. Normalize
        // only its configured token endpoint for oauth2-rs's RFC 8628 decoder.
        if github_poll
            && status == oauth2::http::StatusCode::OK
            && let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes)
            && value.get("error").is_some()
        {
            if value.get("access_token").is_some() {
                // A mixed success/error is a terminal protocol error, not
                // a network failure eligible for RFC 8628 timeout backoff.
                return result
                    .status(oauth2::http::StatusCode::BAD_REQUEST)
                    .body(br#"{"error":"invalid_request"}"#.to_vec())
                    .map_err(|_| Error::Authentication);
            }
            result = result.status(oauth2::http::StatusCode::BAD_REQUEST);
        }
        result.body(bytes).map_err(|_| Error::Authentication)
    }
}
