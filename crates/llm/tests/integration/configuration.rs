// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{TestResult, messages, read_request, upstream};
use std::{path::Path, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
    process::Command,
    time::timeout,
};
use weaver_llm::{Configuration, Error, Options};

const WATCHDOG: Duration = Duration::from_secs(5);
const REPLY: &str = concat!(
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
    r#"{"id":"one","model":"configured","choices":[{"index":0,"message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}]}"#,
);
const MODE: &str = "WEAVER_CONFIG_TEST_MODE";
const SECRET: &str = "WEAVER_CONFIG_TEST_SECRET";
const CONFIG: &str = "WEAVER_CONFIG_TEST_PATH";

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn prepared_profile_streams_after_inputs_are_removed() -> TestResult {
    timeout(WATCHDOG, async {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("weaver.toml");
        let key = dir.path().join("token");
        secret(&key, "snake-oil-stream").await?;
        let (url, observed) = upstream(concat!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
            "data: {\"id\":\"stream\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"}}]}\n\n",
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n",
        )).await?;
        tokio::fs::write(&path, profile(&url, r#"file = "token""#)).await?;
        let prepared = Configuration::load(&path).await?.prepare("local").await?;
        tokio::fs::remove_file(&path).await?;
        tokio::fs::remove_file(&key).await?;
        let mut stream = prepared.stream_turn(&messages(), &Options::default()).await?;
        drop(prepared);
        let mut text = String::new();
        let mut complete = false;
        while let Some(event) = stream.next_event().await? {
            match event {
                weaver_llm::TurnEvent::Text(delta) => text.push_str(&delta),
                weaver_llm::TurnEvent::Finished { .. } => complete = true,
            }
        }
        assert_eq!(text, "Hi");
        assert!(complete);
        let (headers, body) = observed.await??;
        assert!(headers.contains("authorization: bearer snake-oil-stream\r\n"));
        assert_eq!(body["model"], "configured");
        assert_eq!(body["stream"], true);
        Ok::<_, Box<dyn std::error::Error>>(())
    }).await?
}

fn profile(endpoint: &str, credential: &str) -> String {
    format!(
        r#"
[profiles.local]
kind = "direct"
protocol = "openai-chat-completions"
endpoint = "{endpoint}"
model = "configured"
timeout_ms = 1000
max_response_bytes = 4096
[profiles.local.credential]
{credential}
"#
    )
}

async fn secret(path: &Path, value: &str) -> TestResult {
    // Create private permissions before writing any bytes.
    let mut options = tokio::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options.open(path).await?;
    use tokio::io::AsyncWriteExt;
    file.write_all(value.as_bytes()).await?;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn file_profile_binds_model_and_rotates_only_on_prepare() -> TestResult {
    timeout(WATCHDOG, async {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("weaver.toml");
        let key = dir.path().join("token");
        secret(&key, "snake-oil-a\n").await?;
        let (url, observed_a) = upstream(REPLY).await?;
        tokio::fs::write(&path, profile(&url, r#"file = "token""#)).await?;
        let config = Configuration::load(&path).await?;
        let prepared = config.prepare("local").await?;
        assert_eq!(format!("{prepared:?}"), "PreparedProfile { .. }");
        tokio::fs::write(&key, "snake-oil-b").await?;
        let (replacement_url, observed_b) = upstream(REPLY).await?;
        tokio::fs::write(
            &path,
            profile(&replacement_url, r#"file = "token""#).replace("configured", "replacement"),
        )
        .await?;
        let completion = prepared.complete(&messages(), &Options::default()).await?;
        assert_eq!(completion.choices[0].message.content, "Hi");
        let (headers, body) = observed_a.await??;
        assert!(headers.contains("authorization: bearer snake-oil-a\r\n"));
        assert_eq!(body["model"], "configured");
        // Reloading activates both the new trusted destination and credential.
        let replacement = Configuration::load(&path).await?.prepare("local").await?;
        drop(config);
        tokio::fs::remove_file(&key).await?;
        replacement
            .complete(&messages(), &Options::default())
            .await?;
        let (headers, body) = observed_b.await??;
        assert!(headers.contains("authorization: bearer snake-oil-b\r\n"));
        assert_eq!(body["model"], "replacement");
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn configured_protocols_use_the_existing_codecs_and_authentication() -> TestResult {
    timeout(WATCHDOG, async {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("weaver.toml");
        secret(&dir.path().join("token"), "snake-oil-protocol").await?;
        for (protocol, reply, authentication) in [
            ("openai-responses",
             r#"{"id":"response","model":"configured","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi"}]}]}"#,
             "authorization: bearer snake-oil-protocol\r\n"),
            ("anthropic-messages",
             r#"{"id":"message","model":"configured","role":"assistant","content":[{"type":"text","text":"Hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#,
             "x-api-key: snake-oil-protocol\r\n"),
        ] {
            let (url, observed) = upstream(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{reply}")).await?;
            let document = profile(&url, r#"file = "token""#).replace("openai-chat-completions", protocol);
            tokio::fs::write(&path, document).await?;
            let prepared = Configuration::load(&path).await?.prepare("local").await?;
            let completion = prepared.complete(&messages(), &Options::default()).await?;
            assert_eq!(completion.choices[0].message.content, "Hi");
            let (headers, body) = observed.await??;
            assert!(headers.contains(authentication));
            let excluded = if protocol == "anthropic-messages" {
                "authorization:"
            } else {
                "x-api-key:"
            };
            assert!(!headers.contains(excluded));
            assert_eq!(body["model"], "configured");
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    }).await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn anthropic_oauth_and_explicit_bearer_use_exclusive_authorization() -> TestResult {
    timeout(WATCHDOG, async {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("weaver.toml");
        let key = dir.path().join("token");
        secret(&key, "initial").await?;
        let reply = concat!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
            r#"{"id":"message","model":"configured","role":"assistant","content":[{"type":"text","text":"Hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#,
        );
        for (token, authentication) in [
            ("sk-ant-oat-snake-oil", "provider_default"),
            ("opaque-snake-oil-access-token", "bearer"),
        ] {
            let (url, observed) = upstream(reply).await?;
            tokio::fs::write(&key, token).await?;
            let document = profile(&url, r#"file = "token""#)
                .replace("openai-chat-completions", "anthropic-messages")
                .replace("kind = \"direct\"", &format!("kind = \"direct\"\nauthentication = \"{authentication}\""));
            tokio::fs::write(&path, document).await?;
            let prepared = Configuration::load(&path).await?.prepare("local").await?;
            let completion = prepared.complete(&messages(), &Options::default()).await?;
            assert_eq!(completion.choices[0].message.content, "Hi");
            let (headers, _) = observed.await??;
            assert!(headers.contains(&format!("authorization: bearer {token}\r\n")));
            assert!(!headers.contains("x-api-key:"));
            assert!(headers.contains("anthropic-version: 2023-06-01\r\n"));
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    }).await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rejects_ambiguous_unknown_and_invalid_configuration_without_sending() -> TestResult {
    timeout(WATCHDOG, async {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("weaver.toml");
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let url = format!("http://{}/model", listener.local_addr()?);
        secret(&dir.path().join("token"), "snake-oil-valid").await?;
        let valid = profile(&url, r#"file = "token""#);
        tokio::fs::write(&path, &valid).await?;
        Configuration::load(&path).await?.prepare("local").await?;
        let documents = [
            valid.replace("kind = \"direct\"", "kind = \"governed\""),
            valid.replace("openai-chat-completions", "unknown-protocol"),
            valid.replace(
                "kind = \"direct\"",
                "kind = \"direct\"\nauthentication = \"unknown\"",
            ),
            valid.replace("model = \"configured\"", "model = \"\""),
            valid.replace("timeout_ms = 1000", "timeout_ms = 0"),
            valid.replace("max_response_bytes = 4096", "max_response_bytes = 0"),
            valid.replace(&url, "http://remote.invalid/model"),
            valid.replace(&url, "https://user:snake-oil@remote.invalid/model"),
            valid.replace(&url, "https://remote.invalid/model#fragment"),
            format!("{valid}\nfile = \"token\""),
            format!("{valid}\ntoken = \"snake-oil-must-stay-private\""),
            format!("{valid}\nenv = \"ambiguous\""),
            profile(&url, r#"env = """#),
            profile(&url, r#"env = "INVALID=ENV""#),
            profile(&url, r#"env = "WEAVER_MISSING_CONFIG_CREDENTIAL""#),
            format!("{valid}\n[unexpected]\nvalue = true"),
        ];
        for document in documents {
            tokio::fs::write(&path, document).await?;
            let error = match Configuration::load(&path).await {
                Err(error) => error,
                Ok(config) => config
                    .prepare("local")
                    .await
                    .err()
                    .ok_or("accepted invalid profile")?,
            };
            assert!(matches!(error, Error::Configuration));
            assert_eq!(error.to_string(), "invalid model client configuration");
            assert!(!format!("{error:?}").contains("snake-oil"));
        }
        assert!(
            timeout(Duration::from_millis(50), listener.accept())
                .await
                .is_err()
        );
        tokio::fs::write(&path, vec![b'x'; 256 * 1024 + 1]).await?;
        assert!(matches!(
            Configuration::load(&path).await,
            Err(Error::Configuration)
        ));
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rejects_missing_empty_oversized_and_injected_file_credentials() -> TestResult {
    timeout(WATCHDOG, async {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("weaver.toml");
        let key = dir.path().join("token");
        tokio::fs::write(
            &path,
            profile("https://provider.invalid/model", r#"file = "token""#),
        )
        .await?;
        let config = Configuration::load(&path).await?;
        assert!(matches!(
            config.prepare("missing").await,
            Err(Error::Configuration)
        ));
        assert!(matches!(
            config.prepare("local").await,
            Err(Error::Configuration)
        ));
        secret(&key, "").await?;
        for value in [
            "".to_owned(),
            "x".repeat(16 * 1024 + 1),
            "key\r\nX-Injected: yes".to_owned(),
            " key ".to_owned(),
        ] {
            tokio::fs::write(&key, value).await?;
            assert!(matches!(
                config.prepare("local").await,
                Err(Error::Configuration)
            ));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tokio::fs::write(&key, "snake-oil").await?;
            tokio::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o644)).await?;
            assert!(matches!(
                config.prepare("local").await,
                Err(Error::Configuration)
            ));
        }
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn redirect_never_forwards_the_credential() -> TestResult {
    timeout(WATCHDOG, async {
        let dir = tempfile::tempdir()?;
        secret(&dir.path().join("token"), "snake-oil").await?;
        let destination = TcpListener::bind("127.0.0.1:0").await?;
        let redirect = format!("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://{}/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", destination.local_addr()?);
        let (url, observed) = upstream(redirect).await?;
        let path = dir.path().join("weaver.toml");
        tokio::fs::write(&path, profile(&url, r#"file = "token""#)).await?;
        let prepared = Configuration::load(&path).await?.prepare("local").await?;
        assert!(matches!(prepared.complete(&messages(), &Options::default()).await, Err(Error::Status(307))));
        assert!(observed.await??.0.contains("authorization: bearer snake-oil\r\n"));
        assert!(timeout(Duration::from_millis(50), destination.accept()).await.is_err());
        Ok::<_, Box<dyn std::error::Error>>(())
    }).await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn environment_resolution_and_tool_isolation() -> TestResult {
    timeout(WATCHDOG, async {
        match std::env::var(MODE).as_deref() {
            Ok("tool") => {
                assert!(std::env::var_os(SECRET).is_none());
                return Ok(());
            }
            Ok("resolve") => {
                let config = Configuration::load(std::env::var(CONFIG)?).await?;
                let prepared = config.prepare("local").await?;
                prepared.complete(&messages(), &Options::default()).await?;
                let mut tool = Command::new(std::env::current_exe()?);
                tool.args([
                    "--exact",
                    "configuration::environment_resolution_and_tool_isolation",
                ])
                .env(MODE, "tool")
                .kill_on_drop(true);
                for name in config.credential_environment() {
                    tool.env_remove(name);
                }
                assert!(tool.status().await?.success());
                return Ok(());
            }
            _ => {}
        }
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("weaver.toml");
        let (url, observed) = upstream(REPLY).await?;
        let mut document = profile(&url, &format!("env = \"{SECRET}\""));
        // An unselected profile's absent credential must not block this one.
        document.push_str(
            &profile(
                "https://unused.invalid/model",
                r#"env = "WEAVER_CONFIG_UNSELECTED_MISSING""#,
            )
            .replace("profiles.local", "profiles.unused"),
        );
        tokio::fs::write(&path, document).await?;
        let output = Command::new(std::env::current_exe()?)
            .args([
                "--exact",
                "configuration::environment_resolution_and_tool_isolation",
            ])
            .env(MODE, "resolve")
            .env(CONFIG, &path)
            .env(SECRET, "snake-oil-env")
            .kill_on_drop(true)
            .output()
            .await?;
        assert!(
            output.status.success(),
            "child configuration qualification failed"
        );
        assert!(!String::from_utf8_lossy(&output.stdout).contains("snake-oil-env"));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("snake-oil-env"));
        assert!(
            observed
                .await??
                .0
                .contains("authorization: bearer snake-oil-env\r\n")
        );
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dropping_a_turn_closes_an_incomplete_exchange() -> TestResult {
    use tokio_stream::StreamExt;
    timeout(WATCHDOG, async {
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("weaver.toml");
        secret(&directory.path().join("token"), "snake-oil-cancel").await?;
        tokio::fs::write(
            &path,
            profile(
                &format!("http://{}/model", listener.local_addr()?),
                r#"file = "token""#,
            ),
        )
        .await?;
        let prepared = Configuration::load(&path).await?.prepare("local").await?;
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await?;
            let mut socket = BufReader::new(socket);
            let (headers, request) = read_request(&mut socket).await?;
            assert!(headers.contains("authorization: bearer snake-oil-cancel\r\n"));
            assert_eq!(request["model"], "configured");
            socket.get_mut().write_all(concat!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 4096\r\n\r\n",
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"First\"}}]}\n\n",
        ).as_bytes()).await?;
            socket.read(&mut [0]).await
        });
        let turn = prepared
            .stream_turn(&messages(), &Options::default())
            .await?;
        let mut turn = Box::pin(turn.into_stream());
        assert_eq!(
            turn.next().await.transpose()?,
            Some(weaver_llm::TurnEvent::Text("First".into()))
        );
        drop(turn);
        let read = tokio::time::timeout(Duration::from_secs(2), server).await??;
        assert_eq!(read?, 0);
        Ok(())
    })
    .await?
}
