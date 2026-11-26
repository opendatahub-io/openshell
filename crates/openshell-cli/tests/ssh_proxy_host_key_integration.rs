// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

mod helpers;

use bytes::Bytes;
use helpers::{Environment, tempdir};
use http_body_util::{BodyExt, StreamBody};
use hyper::body::{Frame, Incoming};
use hyper::service::service_fn;
use hyper_util::rt::{TokioExecutor, TokioIo};
use openshell_core::proto::datamodel::v1::ObjectMeta;
use openshell_core::proto::{
    CreateSshSessionResponse, RevokeSshSessionResponse, Sandbox, SandboxResponse, TcpForwardFrame,
    tcp_forward_frame,
};
use openshell_core::ssh_host_key::REQUIRE_HOST_KEY_ENV;
use prost::Message;
use russh::keys::ssh_key::private::Ed25519Keypair;
use russh::keys::{HashAlg, PrivateKey};
use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::Path;
use std::process::{Output, Stdio};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio_stream::wrappers::ReceiverStream;

const SANDBOX: &str = "my-sb";
const SANDBOX_ID: &str = "sandbox-1";
const WORKSPACE: &str = "team-a";
const PIN_HEADER: &str =
    "# Managed by OpenShell. Rewritten from the gateway-published fingerprint; do not edit.\n";

type GrpcFrames = tokio::sync::mpsc::Sender<Result<Frame<Bytes>, Infallible>>;
type GrpcBody = StreamBody<ReceiverStream<Result<Frame<Bytes>, Infallible>>>;

fn host_key(seed: u8) -> PrivateKey {
    PrivateKey::from(Ed25519Keypair::from_seed(&[seed; 32]))
}

fn fingerprint(key: &PrivateKey) -> String {
    key.public_key().fingerprint(HashAlg::Sha256).to_string()
}

/// The pin file `ssh-proxy` leaves behind: holding `key`, or no key at all.
fn pin_content(key: Option<&PrivateKey>) -> String {
    key.map_or_else(
        || PIN_HEADER.to_string(),
        |key| {
            format!(
                "{PIN_HEADER}openshell-{SANDBOX}.{WORKSPACE} {}\n",
                key.public_key().to_openssh().unwrap()
            )
        },
    )
}

/// A gateway that publishes one host-key fingerprint for the sandbox and
/// relays every SSH connection to `sandbox`.
struct Gateway {
    published: String,
    /// Whether it admits the caller without a session token.
    direct: bool,
    sandbox: Box<dyn Fn(DuplexStream) + Send + Sync>,
}

impl Gateway {
    async fn serve(self) -> SocketAddr {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let gateway = Arc::new(self);
        tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                openshell_core::net::set_tcp_nodelay_best_effort(&socket);
                let gateway = gateway.clone();
                let service = service_fn(move |request| {
                    let gateway = gateway.clone();
                    async move { Ok::<_, Infallible>(gateway.respond(request, address).await) }
                });
                tokio::spawn(async move {
                    let _ = hyper::server::conn::http2::Builder::new(TokioExecutor::new())
                        .serve_connection(TokioIo::new(socket), service)
                        .await;
                });
            }
        });
        address
    }

    async fn respond(
        &self,
        request: hyper::Request<Incoming>,
        address: SocketAddr,
    ) -> hyper::Response<GrpcBody> {
        let (frames, body) = tokio::sync::mpsc::channel(16);
        let advertises_direct =
            self.direct && request.uri().path() == "/openshell.v1.OpenShell/GetSandbox";
        match request.uri().path() {
            "/openshell.v1.OpenShell/GetSandbox" => {
                let found = SandboxResponse {
                    sandbox: Some(Sandbox {
                        metadata: Some(ObjectMeta {
                            id: SANDBOX_ID.to_string(),
                            ..Default::default()
                        }),
                        host_key_fingerprint: self.published.clone(),
                        ..Default::default()
                    }),
                    ..Default::default()
                };
                respond_once(&frames, &found).await;
            }
            "/openshell.v1.OpenShell/CreateSshSession" => {
                let session = CreateSshSessionResponse {
                    sandbox_id: SANDBOX_ID.to_string(),
                    token: "test-token".to_string(),
                    gateway_host: address.ip().to_string(),
                    gateway_port: u32::from(address.port()),
                    gateway_scheme: "http".to_string(),
                    ..Default::default()
                };
                respond_once(&frames, &session).await;
            }
            "/openshell.v1.OpenShell/RevokeSshSession" => {
                respond_once(&frames, &RevokeSshSessionResponse::default()).await;
            }
            "/openshell.v1.OpenShell/ForwardTcp" => {
                let (relay_end, sandbox_end) = tokio::io::duplex(64 * 1024);
                (self.sandbox)(sandbox_end);
                tokio::spawn(relay(request.into_body(), relay_end, frames));
            }
            _ => {}
        }
        let mut response = hyper::Response::new(StreamBody::new(ReceiverStream::new(body)));
        response
            .headers_mut()
            .insert("content-type", "application/grpc".parse().unwrap());
        if advertises_direct {
            response.headers_mut().insert(
                openshell_core::forward::DIRECT_SSH_HEADER,
                "1".parse().unwrap(),
            );
        }
        response
    }
}

fn grpc_message(message: &impl Message) -> Frame<Bytes> {
    let encoded = message.encode_to_vec();
    let mut framed = vec![0];
    framed.extend_from_slice(&u32::try_from(encoded.len()).unwrap().to_be_bytes());
    framed.extend_from_slice(&encoded);
    Frame::data(framed.into())
}

fn grpc_status(status: tonic::Status) -> Frame<Bytes> {
    Frame::trailers(status.into_http::<()>().into_parts().0.headers)
}

async fn respond_once(frames: &GrpcFrames, message: &impl Message) {
    let _ = frames.send(Ok(grpc_message(message))).await;
    let _ = frames.send(Ok(grpc_status(tonic::Status::ok("")))).await;
}

/// Copies `ForwardTcp` data frames to the sandbox and the sandbox's bytes back.
async fn relay(mut inbound: Incoming, sandbox: DuplexStream, frames: GrpcFrames) {
    let (mut from_sandbox, mut to_sandbox) = tokio::io::split(sandbox);
    let to_sandbox = tokio::spawn(async move {
        let mut pending = Vec::new();
        while let Some(Ok(frame)) = inbound.frame().await {
            let Ok(data) = frame.into_data() else {
                continue;
            };
            pending.extend_from_slice(&data);
            while let Some(length) = pending
                .get(1..5)
                .map(|length| u32::from_be_bytes(length.try_into().unwrap()) as usize)
                .filter(|length| pending.len() >= 5 + length)
            {
                let frame = TcpForwardFrame::decode(&pending[5..5 + length]).unwrap();
                pending.drain(..5 + length);
                if let Some(tcp_forward_frame::Payload::Data(data)) = frame.payload
                    && to_sandbox.write_all(&data).await.is_err()
                {
                    return;
                }
            }
        }
        let _ = to_sandbox.shutdown().await;
    });
    // Smaller than any key exchange packet, so the proxy has to reassemble
    // each one.
    let mut chunk = [0_u8; 97];
    while let Ok(read @ 1..) = from_sandbox.read(&mut chunk).await {
        let frame = TcpForwardFrame {
            payload: Some(tcp_forward_frame::Payload::Data(chunk[..read].to_vec())),
        };
        if frames.send(Ok(grpc_message(&frame))).await.is_err() {
            break;
        }
    }
    let _ = frames.send(Ok(grpc_status(tonic::Status::ok("")))).await;
    to_sandbox.abort();
}

/// The `ssh-proxy` arguments of a generated config entry.
fn name_mode(gateway: SocketAddr, known_hosts: &Path) -> String {
    let known_hosts = known_hosts.display();
    format!("{} --known-hosts {known_hosts}", old_name_mode(gateway))
}

/// The same, as releases before host-key verification generated them.
fn old_name_mode(gateway: SocketAddr) -> String {
    format!("ssh-proxy --server http://{gateway} --name {SANDBOX} --workspace {WORKSPACE}")
}

/// Runs `command` to completion. Without `require_host_key`, the user set
/// `OPENSHELL_SSH_REQUIRE_HOST_KEY=0`.
async fn finished(
    mut command: tokio::process::Command,
    config: &Path,
    require_host_key: bool,
) -> Output {
    if require_host_key {
        command.env_remove(REQUIRE_HOST_KEY_ENV);
    } else {
        command.env(REQUIRE_HOST_KEY_ENV, "0");
    }
    let run = command
        .env("XDG_CONFIG_HOME", config)
        .env("OPENSHELL_TELEMETRY_ENABLED", "false")
        .env_remove("OPENSHELL_GATEWAY")
        .env_remove("OPENSHELL_GATEWAY_ENDPOINT")
        .env_remove("OPENSHELL_WORKSPACE")
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .output();
    tokio::time::timeout(Duration::from_secs(30), run)
        .await
        .expect("the command must exit")
        .unwrap()
}

/// Runs `openshell` with `args`, which are separated by single spaces.
async fn openshell(args: &str, config: &Path, require_host_key: bool) -> Output {
    let mut command = tokio::process::Command::new(env!("CARGO_BIN_EXE_openshell"));
    command.args(args.split(' '));
    finished(command, config, require_host_key).await
}

/// The lines of the refusal that name the sandbox and both keys. The CLI wraps
/// the lines after them to the terminal width.
fn assert_mismatch_reported(stderr: &str, published: &PrivateKey, presented: &PrivateKey) {
    for line in [
        format!("SSH host key mismatch for sandbox '{SANDBOX}' (workspace '{WORKSPACE}')"),
        format!("gateway published: {}", fingerprint(published)),
        format!("server presented:  {}", fingerprint(presented)),
    ] {
        assert!(stderr.contains(&line), "{stderr}");
    }
}

/// What an SSH server presenting `key` sends: up to its key exchange reply,
/// then from the reply to its first encrypted bytes. The proxy does not check
/// block alignment, so every packet has four bytes of padding.
fn handshake(key: &PrivateKey) -> [Vec<u8>; 2] {
    let packet = |payload: &[u8]| {
        let length = u32::try_from(payload.len() + 5).unwrap().to_be_bytes();
        [&length[..], &[4], payload, &[0; 4]].concat()
    };
    let key = key.public_key().to_bytes().unwrap();
    let key_length = u32::try_from(key.len()).unwrap().to_be_bytes();
    let reply = [&[31][..], &key_length, &key, &[0; 127]].concat();
    [
        [
            &b"SSH-2.0-OpenShell_test\r\n"[..],
            &packet(&[&[20][..], &[0; 61]].concat()),
        ]
        .concat(),
        [packet(&reply), packet(&[21]), vec![0xff; 48]].concat(),
    ]
}

/// A sandbox whose SSH server sends `bytes` and hangs up.
fn sending(bytes: Vec<u8>) -> Box<dyn Fn(DuplexStream) + Send + Sync> {
    Box::new(move |mut stream| {
        let bytes = bytes.clone();
        tokio::spawn(async move {
            let _ = stream.write_all(&bytes).await;
        });
    })
}

#[tokio::test]
async fn name_mode_proxy_withholds_a_key_the_gateway_did_not_publish() {
    let published = host_key(1);
    let presented = host_key(2);
    let [before_reply, reply_onward] = handshake(&presented);
    for direct in [false, true] {
        let gateway = Gateway {
            published: fingerprint(&published),
            direct,
            sandbox: sending([before_reply.clone(), reply_onward.clone()].concat()),
        }
        .serve()
        .await;
        let scratch = tempfile::tempdir().unwrap();
        let pin = scratch.path().join("known_hosts/pin");

        let proxy = openshell(&name_mode(gateway, &pin), scratch.path(), false).await;

        let stderr = String::from_utf8_lossy(&proxy.stderr);
        assert_eq!(proxy.status.code(), Some(1), "{stderr}");
        assert!(
            before_reply.starts_with(&proxy.stdout),
            "no byte of the key exchange reply may reach ssh"
        );
        assert_mismatch_reported(&stderr, &published, &presented);
        assert_eq!(std::fs::read_to_string(&pin).unwrap(), pin_content(None));
    }
}

/// A gateway that predates sandbox SSH identities publishes nothing.
#[tokio::test]
async fn name_mode_proxy_refuses_a_sandbox_with_no_published_key_unless_allowed() {
    let key = host_key(1);
    let transcript = handshake(&key).concat();
    let gateway = Gateway {
        published: String::new(),
        direct: false,
        sandbox: sending(transcript.clone()),
    }
    .serve()
    .await;
    let scratch = tempfile::tempdir().unwrap();
    let pin = scratch.path().join("known_hosts/pin");

    let proxy = openshell(&name_mode(gateway, &pin), scratch.path(), false).await;

    let stderr = String::from_utf8_lossy(&proxy.stderr);
    assert!(proxy.status.success(), "{stderr}");
    assert_eq!(proxy.stdout, transcript);
    assert!(
        stderr.contains("warning: SSH host key of sandbox 'my-sb' is NOT verified"),
        "{stderr}"
    );
    assert_eq!(
        std::fs::read_to_string(&pin).unwrap(),
        pin_content(Some(&key))
    );

    let refused = openshell(&name_mode(gateway, &pin), scratch.path(), true).await;

    let stderr = String::from_utf8_lossy(&refused.stderr);
    assert!(!refused.status.success(), "{stderr}");
    assert_eq!(refused.stdout, b"");
    // The error is wrapped to the terminal width.
    assert!(stderr.contains("fingerprint"), "{stderr}");
    assert!(stderr.contains(REQUIRE_HOST_KEY_ENV), "{stderr}");
    assert_eq!(std::fs::read_to_string(&pin).unwrap(), pin_content(None));
}

/// The `ssh` of a config entry from before host-key verification accepts any
/// key. It is refused, unless the user lets unverified connections go ahead.
#[tokio::test]
async fn name_mode_proxy_refuses_an_entry_that_predates_host_key_verification_unless_allowed() {
    let transcript = handshake(&host_key(2)).concat();
    let gateway = Gateway {
        published: fingerprint(&host_key(1)),
        direct: false,
        sandbox: sending(transcript.clone()),
    }
    .serve()
    .await;
    let scratch = tempfile::tempdir().unwrap();
    let args = old_name_mode(gateway);
    let caller = "SSH config entry for sandbox 'my-sb'";

    let proxy = openshell(&args, scratch.path(), false).await;

    let stderr = String::from_utf8_lossy(&proxy.stderr);
    assert!(proxy.status.success(), "{stderr}");
    assert_eq!(proxy.stdout, transcript);
    assert!(stderr.contains(caller), "{stderr}");
    assert!(
        stderr.contains("the SSH host key is NOT verified"),
        "{stderr}"
    );

    let refused = openshell(&args, scratch.path(), true).await;

    let stderr = String::from_utf8_lossy(&refused.stderr);
    assert!(!refused.status.success(), "{stderr}");
    assert_eq!(refused.stdout, b"");
    assert!(stderr.contains(caller), "{stderr}");
    assert!(stderr.contains(REQUIRE_HOST_KEY_ENV), "{stderr}");
}

/// The `ssh` of a client from before host-key verification accepts any key,
/// and its handoff names none.
#[tokio::test]
async fn proxy_refuses_the_handoff_of_a_client_that_predates_host_key_verification() {
    Environment::new()
        .remove(REQUIRE_HOST_KEY_ENV)
        .run_async(async {
            let grant = openshell_core::ssh_handoff::RelayGrant {
                authorization: Some(openshell_core::ssh_handoff::RelayAuthorization::Session(
                    CreateSshSessionResponse::default(),
                )),
                endpoint: "http://127.0.0.1:0".to_string(),
                gateway_name: "test".to_string(),
                replica: None,
                host_key: None,
            };
            let (_issuer, peer) = tokio::io::duplex(8);

            let refusal = openshell_cli::ssh::relay_prepared_ssh(
                grant,
                peer,
                SANDBOX,
                WORKSPACE,
                &openshell_cli::tls::TlsOptions::default(),
            )
            .await
            .unwrap_err();

            assert!(
                refusal.to_string().contains(REQUIRE_HOST_KEY_ENV),
                "{refusal}"
            );
        })
        .await;
}

/// The real `ssh` client against a real SSH server, with `ssh-proxy` as its
/// `ProxyCommand`.
#[cfg(unix)]
mod openssh {
    use super::*;
    use openshell_core::forward::{sandbox_ssh_args, shell_escape};
    use openshell_core::proto::open_shell_client::OpenShellClient;
    use openshell_core::ssh_handoff::SshTarget;
    use russh::server::{Auth, ChannelOpenHandle, Msg, Session};
    use russh::{Channel, ChannelId};
    use std::path::PathBuf;

    const COMMAND: &str = "report-ready";
    const COMMAND_OUTPUT: &str = "ready\n";
    const GATEWAY: &str = "test-gateway";

    fn write_pin(pin: &Path, content: &str) {
        std::fs::create_dir_all(pin.parent().unwrap()).unwrap();
        std::fs::write(pin, content).unwrap();
    }

    /// Accepts every login and answers every command with [`COMMAND_OUTPUT`].
    struct Shell;

    impl russh::server::Handler for Shell {
        type Error = russh::Error;

        async fn auth_none(&mut self, _user: &str) -> Result<Auth, Self::Error> {
            Ok(Auth::Accept)
        }

        async fn channel_open_session(
            &mut self,
            _channel: Channel<Msg>,
            reply: ChannelOpenHandle,
            _session: &mut Session,
        ) -> Result<(), Self::Error> {
            reply.accept().await;
            Ok(())
        }

        async fn exec_request(
            &mut self,
            channel: ChannelId,
            _data: &[u8],
            session: &mut Session,
        ) -> Result<(), Self::Error> {
            session.channel_success(channel)?;
            session.data(channel, COMMAND_OUTPUT)?;
            session.exit_status_request(channel, 0)?;
            session.eof(channel)?;
            session.close(channel)?;
            Ok(())
        }
    }

    /// The gateway in front of a sandbox whose SSH server presents `key`.
    async fn sandbox_presenting(key: &PrivateKey) -> SocketAddr {
        gateway_publishing(key, key, false).await
    }

    /// The same, where the gateway publishes the fingerprint of `published`
    /// and `direct` says whether it admits the caller without a session token.
    async fn gateway_publishing(
        published: &PrivateKey,
        key: &PrivateKey,
        direct: bool,
    ) -> SocketAddr {
        // The supervisor's server also keeps the default algorithms.
        let config = Arc::new(russh::server::Config {
            keys: vec![key.clone()],
            ..Default::default()
        });
        Gateway {
            published: fingerprint(published),
            direct,
            sandbox: Box::new(move |stream| {
                let config = config.clone();
                tokio::spawn(async move {
                    if let Ok(session) = russh::server::run_stream(config, stream, Shell).await {
                        let _ = session.await;
                    }
                });
            }),
        }
        .serve()
        .await
    }

    /// The environment of a client whose config directory is `config`.
    fn client(config: &Path) -> Environment {
        Environment::new()
            .set("XDG_CONFIG_HOME", config)
            .remove(REQUIRE_HOST_KEY_ENV)
    }

    /// The file in which that client pins the sandbox's host key.
    fn client_pin(config: &Path) -> PathBuf {
        config
            .join("openshell/known_hosts")
            .join(GATEWAY)
            .join(format!("openshell-{SANDBOX}.{WORKSPACE}"))
    }

    /// Runs [`COMMAND`] the way the CLI and TUI do: through the proxy they
    /// prepare for the sandbox, with the `ssh` arguments built from it. `ssh`
    /// takes the first value of an option, so `overrides` win.
    async fn ssh_as_client(gateway: SocketAddr, config: &Path, overrides: &[String]) -> Output {
        let endpoint = format!("http://{gateway}");
        let channel = tonic::transport::Endpoint::from_shared(endpoint.clone())
            .unwrap()
            .connect()
            .await
            .unwrap();
        let client = OpenShellClient::with_interceptor(channel, |request: tonic::Request<()>| {
            Ok::<_, tonic::Status>(request)
        });
        let target = SshTarget::new(&endpoint, GATEWAY, SANDBOX, WORKSPACE, SANDBOX_ID);
        let proxy = target.prepare(client, None).await.unwrap();
        // The client is this test, so its proxy command names the test binary.
        let this_test = std::env::current_exe().unwrap();
        let this_test = shell_escape(&this_test.to_string_lossy()).replace('%', "%%");
        let openshell = shell_escape(env!("CARGO_BIN_EXE_openshell")).replace('%', "%%");
        let arguments = sandbox_ssh_args(proxy.command(), "ERROR")
            .into_iter()
            .map(|argument| argument.replace(&this_test, &openshell));
        let mut ssh = tokio::process::Command::new("ssh");
        ssh.args(["-F", "/dev/null", "-o", "BatchMode=yes"])
            .args(overrides.iter().flat_map(|option| ["-o", option]))
            .args(arguments)
            .args(["sandbox", COMMAND]);
        proxy
            .run(async { Ok(finished(ssh, config, true).await) })
            .await
            .unwrap()
    }

    /// Runs [`COMMAND`] through the config entry `sandbox ssh-config`
    /// prints, with no other configuration and no options of its own.
    async fn ssh_through_config_entry(gateway: SocketAddr, config: &Path) -> Output {
        let gateway_dir = config.join("openshell/gateways").join(GATEWAY);
        std::fs::create_dir_all(&gateway_dir).unwrap();
        let metadata = serde_json::json!({
            "name": GATEWAY,
            "gateway_endpoint": format!("http://{gateway}"),
            "gateway_port": gateway.port(),
            "is_remote": false,
            "auth_mode": "plaintext",
        });
        std::fs::write(gateway_dir.join("metadata.json"), metadata.to_string()).unwrap();

        let print_entry =
            format!("--gateway {GATEWAY} --workspace {WORKSPACE} sandbox ssh-config {SANDBOX}");
        let printed = openshell(&print_entry, config, false).await;
        assert!(
            printed.status.success(),
            "{}",
            String::from_utf8_lossy(&printed.stderr)
        );
        let entry = config.join("ssh_config_entry");
        std::fs::write(&entry, printed.stdout).unwrap();

        let mut ssh = tokio::process::Command::new("ssh");
        ssh.arg("-F")
            .arg(entry)
            .args(["-o", "BatchMode=yes"])
            .args([format!("openshell-{SANDBOX}.{WORKSPACE}").as_str(), COMMAND]);
        finished(ssh, config, true).await
    }

    /// The proxy forwards the published key here, so the refusal is `ssh`'s
    /// own strict check against a file the proxy does not write.
    #[tokio::test]
    async fn ssh_refuses_a_key_missing_from_its_own_known_hosts_file() {
        let scratch = tempdir().unwrap();
        client(scratch.path())
            .run_async(async {
                let key = host_key(1);
                let gateway = sandbox_presenting(&key).await;
                let proxy_pin = client_pin(scratch.path());
                let ssh_pin = scratch.path().join("known_hosts/ssh");
                let another_key = pin_content(Some(&host_key(2)));
                write_pin(&ssh_pin, &another_key);

                let ssh = ssh_as_client(
                    gateway,
                    scratch.path(),
                    &[format!("UserKnownHostsFile=\"{}\"", ssh_pin.display())],
                )
                .await;

                let stderr = String::from_utf8_lossy(&ssh.stderr);
                assert_eq!(ssh.status.code(), Some(255), "{stderr}");
                assert!(stderr.contains("Host key verification failed"), "{stderr}");
                assert_eq!(ssh.stdout, b"");
                assert_eq!(
                    std::fs::read_to_string(&proxy_pin).unwrap(),
                    pin_content(Some(&key)),
                    "the proxy forwarded the key exchange reply"
                );
                assert_eq!(std::fs::read_to_string(&ssh_pin).unwrap(), another_key);
            })
            .await;
    }

    /// `ssh` is already running when the proxy pins the key, so this holds
    /// only because `ssh` reads its known-hosts file when it processes the key
    /// exchange reply, not when it starts. Host-key verification rests on it.
    /// The `%` is one `ssh` would expand in the path it is given.
    #[tokio::test]
    async fn ssh_with_the_client_arguments_reaches_the_published_sandbox() {
        let scratch = tempdir().unwrap();
        let config = scratch.path().join("100% config");
        client(&config)
            .run_async(async {
                let key = host_key(1);
                for direct in [false, true] {
                    let gateway = gateway_publishing(&key, &key, direct).await;

                    let ssh = ssh_as_client(gateway, &config, &[]).await;

                    let stderr = String::from_utf8_lossy(&ssh.stderr);
                    assert!(ssh.status.success(), "{stderr}");
                    assert_eq!(String::from_utf8_lossy(&ssh.stdout), COMMAND_OUTPUT);
                    assert_eq!(
                        std::fs::read_to_string(client_pin(&config)).unwrap(),
                        pin_content(Some(&key))
                    );
                    std::fs::remove_file(client_pin(&config)).unwrap();
                }
            })
            .await;
    }

    #[tokio::test]
    async fn ssh_with_the_client_arguments_never_reaches_another_server() {
        let scratch = tempdir().unwrap();
        client(scratch.path())
            .run_async(async {
                let presented = host_key(1);
                let published = host_key(2);
                for direct in [false, true] {
                    let gateway = gateway_publishing(&published, &presented, direct).await;

                    let ssh = ssh_as_client(gateway, scratch.path(), &[]).await;

                    let stderr = String::from_utf8_lossy(&ssh.stderr);
                    assert_eq!(ssh.status.code(), Some(255), "{stderr}");
                    assert_mismatch_reported(&stderr, &published, &presented);
                    assert_eq!(ssh.stdout, b"");
                    assert_eq!(
                        std::fs::read_to_string(client_pin(scratch.path())).unwrap(),
                        pin_content(None)
                    );
                }
            })
            .await;
    }

    /// The pin still holds the stale key when `ssh` starts, so this holds only
    /// because the proxy replaces it before `ssh` reads the file.
    #[tokio::test]
    async fn ssh_connects_through_the_generated_config_entry_despite_a_stale_pin() {
        let key = host_key(1);
        let gateway = sandbox_presenting(&key).await;
        let scratch = tempfile::tempdir().unwrap();
        let config = scratch.path().join("100% config");
        let pin = config
            .join("openshell/known_hosts")
            .join(GATEWAY)
            .join(format!("openshell-{SANDBOX}.{WORKSPACE}"));
        write_pin(&pin, &pin_content(Some(&host_key(2))));

        let ssh = ssh_through_config_entry(gateway, &config).await;

        let stderr = String::from_utf8_lossy(&ssh.stderr);
        assert!(ssh.status.success(), "{stderr}");
        assert_eq!(String::from_utf8_lossy(&ssh.stdout), COMMAND_OUTPUT);
        assert_eq!(
            std::fs::read_to_string(&pin).unwrap(),
            pin_content(Some(&key))
        );
    }
}
