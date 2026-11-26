// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

use futures::StreamExt;
use openshell_core::proto::{self, TcpForwardFrame, tcp_forward_frame};
use openshell_server::test_support::grpc::open_shell_server::{OpenShell, OpenShellServer};
use std::net::SocketAddr;
use std::process::Stdio;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio_stream::wrappers::TcpListenerStream;
use tonic::{Request, Response, Status};

const TOKEN: &str = "test-ssh-session";

#[derive(Clone, Copy)]
enum Admission {
    Legacy,
    Direct,
    RejectDirect(tonic::Code),
}

struct Gateway {
    admissions: Vec<Admission>,
    lookups: AtomicUsize,
    direct_opens: AtomicUsize,
    minted: AtomicBool,
    relay_status: Status,
    port: u16,
    revoked: AtomicBool,
    stall_open: Option<Arc<tokio::sync::Notify>>,
    reset_transport: Arc<tokio::sync::Notify>,
}

impl Gateway {
    async fn start(
        admissions: Vec<Admission>,
        relay_status: Status,
        stall_open: Option<Arc<tokio::sync::Notify>>,
    ) -> (SocketAddr, Arc<Self>, tokio::task::AbortHandle) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let gateway = Arc::new(Self {
            admissions,
            lookups: AtomicUsize::default(),
            direct_opens: AtomicUsize::default(),
            minted: AtomicBool::default(),
            relay_status,
            port: address.port(),
            revoked: AtomicBool::default(),
            stall_open,
            reset_transport: Arc::default(),
        });
        let server = tokio::spawn(
            tonic::transport::Server::builder()
                .add_service(OpenShellServer::from_arc(gateway.clone()))
                .serve_with_incoming(TcpListenerStream::new(listener)),
        );
        (address, gateway, server.abort_handle())
    }

    fn admission(&self) -> Result<Admission, Status> {
        let index = self.lookups.load(Ordering::SeqCst).saturating_sub(1);
        self.admissions
            .get(index)
            .copied()
            .ok_or_else(|| Status::permission_denied("unexpected SSH reconnect"))
    }
}

#[tonic::async_trait]
impl OpenShell for Gateway {
    async fn get_sandbox(
        &self,
        req: Request<proto::GetSandboxRequest>,
    ) -> Result<Response<proto::SandboxResponse>, Status> {
        let metadata = proto::datamodel::v1::ObjectMeta {
            id: "id-repro".into(),
            ..proto::datamodel::v1::ObjectMeta::default()
        };
        let mut response = Response::new(proto::SandboxResponse {
            sandbox: Some(proto::Sandbox {
                metadata: Some(metadata),
                ..proto::Sandbox::default()
            }),
            ..proto::SandboxResponse::default()
        });
        // Only a connection lookup advances the script. Lifecycle polls also call GetSandbox.
        if self.admissions.len() > 1
            && req
                .metadata()
                .contains_key(openshell_core::replica_routing::OWNER_REQUEST_HEADER)
        {
            self.lookups.fetch_add(1, Ordering::SeqCst);
        }
        if !matches!(self.admission()?, Admission::Legacy) {
            response.metadata_mut().insert(
                openshell_core::forward::DIRECT_SSH_HEADER,
                "1".parse().unwrap(),
            );
        }
        Ok(response)
    }

    async fn create_ssh_session(
        &self,
        _: Request<proto::CreateSshSessionRequest>,
    ) -> Result<Response<proto::CreateSshSessionResponse>, Status> {
        self.minted.store(true, Ordering::SeqCst);
        Ok(Response::new(proto::CreateSshSessionResponse {
            sandbox_id: "id-repro".into(),
            token: TOKEN.into(),
            gateway_host: "127.0.0.1".into(),
            gateway_port: self.port.into(),
            gateway_scheme: "http".into(),
            ..proto::CreateSshSessionResponse::default()
        }))
    }

    async fn forward_tcp(
        &self,
        req: Request<tonic::Streaming<TcpForwardFrame>>,
    ) -> Result<Response<tonic::codegen::BoxStream<TcpForwardFrame>>, Status> {
        let mut inbound = req.into_inner();
        let Some(tcp_forward_frame::Payload::Init(init)) =
            inbound.message().await?.and_then(|f| f.payload)
        else {
            return Err(Status::invalid_argument("expected init"));
        };
        let admission = self.admission()?;
        match admission {
            Admission::Legacy => {
                assert!(matches!(
                    init.target,
                    Some(proto::tcp_forward_init::Target::Ssh(_))
                ));
                assert_eq!(init.authorization_token, TOKEN);
            }
            Admission::Direct | Admission::RejectDirect(_) => {
                assert!(init.authorization_token.is_empty());
                assert_eq!(
                    init.target,
                    Some(proto::tcp_forward_init::Target::DirectSshSandboxId(
                        "id-repro".into()
                    ))
                );
                self.direct_opens.fetch_add(1, Ordering::SeqCst);
                if let Admission::RejectDirect(code) = admission {
                    return Err(Status::new(code, "SSHREFUSED"));
                }
            }
        }
        if let Some(started) = &self.stall_open {
            started.notify_one();
            return std::future::pending().await;
        }
        let status = self.relay_status.clone();
        let reset_transport = (self.admissions.len() > 1
            && self.lookups.load(Ordering::SeqCst) == 1)
            .then(|| self.reset_transport.clone());
        let stream = futures::stream::once(async move {
            // Leave stdin open after one chunk traverses the proxy.
            let frame = inbound.message().await.unwrap().unwrap();
            assert!(matches!(frame.payload, Some(tcp_forward_frame::Payload::Data(data)) if data == b"probe"));
            if let Some(reset_transport) = reset_transport {
                // Keep the admitted relay alive past the connect establishment threshold.
                tokio::time::sleep(Duration::from_millis(2_200)).await;
                reset_transport.notify_waiters();
                return std::future::pending().await;
            }
            (status.code() != tonic::Code::Ok).then_some(Err(status))
        }).filter_map(futures::future::ready);
        Ok(Response::new(Box::pin(stream)))
    }

    async fn revoke_ssh_session(
        &self,
        req: Request<proto::RevokeSshSessionRequest>,
    ) -> Result<Response<proto::RevokeSshSessionResponse>, Status> {
        let req = req.into_inner();
        assert!(req.token == TOKEN, "unexpected token in revocation");
        assert!(req.allow_missing);
        self.revoked.store(true, Ordering::SeqCst);
        Ok(Response::new(proto::RevokeSshSessionResponse::default()))
    }
}

async fn proxy_exits_with_stdin_open(relay_status: Status, admission: Admission) {
    let expected_code = relay_status.code();
    let (address, gateway, server) = Gateway::start(vec![admission], relay_status, None).await;
    let config = tempfile::tempdir().unwrap();
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_openshell"))
        .args([
            "ssh-proxy",
            "--server",
            &format!("http://{address}"),
            "--sandbox",
            "repro",
        ])
        .env("XDG_CONFIG_HOME", config.path())
        .env("OPENSHELL_TELEMETRY_ENABLED", "false")
        // Started without `--known-hosts`, the proxy verifies no host key.
        .env("OPENSHELL_SSH_REQUIRE_HOST_KEY", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(b"probe").await.unwrap();
    let status = tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .expect("SSH proxy must exit even while the parent holds stdin open")
        .unwrap();
    drop(stdin);
    let mut stderr = String::new();
    tokio::io::AsyncReadExt::read_to_string(child.stderr.as_mut().unwrap(), &mut stderr)
        .await
        .unwrap();
    if matches!(admission, Admission::RejectDirect(_)) {
        assert!(
            !status.success() && stderr.contains("SSHREFUSED"),
            "{stderr}"
        );
    } else if expected_code == tonic::Code::Ok {
        assert!(status.success(), "{stderr}");
    } else {
        assert!(!status.success(), "relay failure must propagate to SSH");
        assert!(stderr.contains("Deadline expired"), "{stderr}");
    }
    assert_eq!(
        gateway.minted.load(Ordering::SeqCst),
        matches!(admission, Admission::Legacy)
    );
    assert_eq!(
        gateway.revoked.load(Ordering::SeqCst),
        matches!(admission, Admission::Legacy)
    );
    server.abort();
}

#[tokio::test]
async fn dropping_handoff_cancels_a_stalled_relay_open() {
    let started = Arc::new(tokio::sync::Notify::new());
    let (address, _, server) = Gateway::start(
        vec![Admission::Legacy],
        Status::ok(""),
        Some(started.clone()),
    )
    .await;
    let (owner, peer) = tokio::io::duplex(8);
    let config = tempfile::tempdir().unwrap();
    let known_hosts = config.path().join("known_hosts");
    let proxy = tokio::spawn(async move {
        let grant = openshell_core::ssh_handoff::RelayGrant {
            authorization: Some(openshell_core::ssh_handoff::RelayAuthorization::Session(
                proto::CreateSshSessionResponse {
                    sandbox_id: "id-repro".into(),
                    token: TOKEN.into(),
                    gateway_scheme: "http".into(),
                    gateway_host: "127.0.0.1".into(),
                    gateway_port: address.port().into(),
                    ..proto::CreateSshSessionResponse::default()
                },
            )),
            endpoint: format!("http://{address}"),
            gateway_name: "test".into(),
            replica: None,
            host_key: Some(openshell_core::ssh_handoff::HostKeyHandoff {
                expectation: "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA".into(),
                known_hosts: known_hosts.display().to_string(),
            }),
        };
        openshell_cli::ssh::relay_prepared_ssh(
            grant,
            peer,
            "repro",
            "default",
            &openshell_cli::tls::TlsOptions::default(),
        )
        .await
    });
    tokio::time::timeout(Duration::from_secs(5), started.notified())
        .await
        .unwrap();
    drop(owner);
    let result = tokio::time::timeout(Duration::from_secs(2), proxy)
        .await
        .expect("proxy must leave the blocked RPC when the issuer exits")
        .unwrap();
    assert!(result.is_err());
    server.abort();
}

#[tokio::test]
async fn proxy_exits_after_relay_error_with_stdin_open() {
    proxy_exits_with_stdin_open(
        Status::deadline_exceeded("relay open timed out"),
        Admission::Legacy,
    )
    .await;
}

#[tokio::test]
async fn proxy_exits_after_clean_relay_close_with_stdin_open() {
    proxy_exits_with_stdin_open(Status::ok(""), Admission::Legacy).await;
}

#[tokio::test]
async fn advertised_direct_ssh_never_mints_even_when_rejected() {
    proxy_exits_with_stdin_open(Status::ok(""), Admission::Direct).await;
    for code in [
        tonic::Code::PermissionDenied,
        tonic::Code::FailedPrecondition,
        tonic::Code::Unimplemented,
    ] {
        proxy_exits_with_stdin_open(Status::ok(""), Admission::RejectDirect(code)).await;
    }
}

#[cfg(unix)]
fn proxying_ssh_config() -> tempfile::TempDir {
    use std::os::unix::fs::PermissionsExt;

    let config = tempfile::tempdir().unwrap();
    let ssh = config.path().join("ssh");
    std::fs::write(
        &ssh,
        r#"#!/bin/sh
for arg do
    case "$arg" in
        ProxyCommand=*) printf probe | /bin/sh -c "${arg#ProxyCommand=}"; exit 255 ;;
    esac
done
exit 1
"#,
    )
    .unwrap();
    std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o700)).unwrap();
    config
}

#[cfg(unix)]
fn sandbox_cli(config: &tempfile::TempDir, address: SocketAddr) -> tokio::process::Command {
    let mut cli = tokio::process::Command::new(env!("CARGO_BIN_EXE_openshell"));
    cli.args([
        "--gateway",
        "test",
        "--gateway-endpoint",
        &format!("http://{address}"),
        "sandbox",
    ])
    .env("PATH", config.path())
    .env("XDG_CONFIG_HOME", config.path())
    .env("OPENSHELL_TELEMETRY_ENABLED", "false")
    // The gateway of these tests publishes no host key.
    .env("OPENSHELL_SSH_REQUIRE_HOST_KEY", "0")
    .kill_on_drop(true);
    cli
}

#[cfg(unix)]
#[tokio::test]
async fn connect_recovers_after_tcp_reset_but_stops_on_direct_refusal_or_capability_loss() {
    let config = proxying_ssh_config();
    for (replacement, expected_direct_opens) in [
        (Admission::RejectDirect(tonic::Code::PermissionDenied), 2),
        (Admission::Legacy, 1),
    ] {
        let (address, gateway, server) = Gateway::start(
            // An extra lookup after a refusal reaches a legacy-only gateway.
            vec![Admission::Direct, replacement, Admission::Legacy],
            Status::unavailable("connection lost"),
            None,
        )
        .await;
        // Reset established TCP connections while the gateway keeps accepting reconnects.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_address = listener.local_addr().unwrap();
        let reset = gateway.reset_transport.clone();
        let bridge = tokio::spawn(async move {
            while let Ok((mut downstream, _)) = listener.accept().await {
                let reset = reset.clone();
                tokio::spawn(async move {
                    let mut upstream =
                        openshell_core::net::connect_tcp_nodelay_best_effort(address)
                            .await
                            .unwrap();
                    tokio::select! {
                        () = reset.notified() => downstream.set_zero_linger().unwrap(),
                        _ = tokio::io::copy_bidirectional(&mut downstream, &mut upstream) => {}
                    }
                });
            }
        });
        let output = tokio::time::timeout(
            Duration::from_secs(10),
            sandbox_cli(&config, relay_address)
                .args(["connect", "repro"])
                .output(),
        )
        .await
        .expect("connect must stop during recovery")
        .unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(!output.status.success(), "{stderr}");
        assert!(
            !gateway.minted.load(Ordering::SeqCst),
            "minted a legacy SSH session during recovery: {stderr}"
        );
        assert_eq!(gateway.lookups.load(Ordering::SeqCst), 2, "{stderr}");
        assert_eq!(
            gateway.direct_opens.load(Ordering::SeqCst),
            expected_direct_opens,
            "{stderr}"
        );
        bridge.abort();
        server.abort();
    }
}

#[cfg(unix)]
#[tokio::test]
async fn download_stops_on_direct_refusal_even_with_transport_words_in_the_path() {
    let config = proxying_ssh_config();
    for admission in [
        Admission::RejectDirect(tonic::Code::PermissionDenied),
        Admission::Direct,
    ] {
        let (address, gateway, server) = Gateway::start(
            vec![admission],
            Status::permission_denied("SSHREFUSED"),
            None,
        )
        .await;
        let dest = config.path().join("download");
        for (index, path) in ["plain.bin", "connection-roundtrip.bin"]
            .into_iter()
            .enumerate()
        {
            let output = sandbox_cli(&config, address)
                .args(["download", "repro", path])
                .arg(&dest)
                .output()
                .await
                .unwrap();
            assert!(!output.status.success());
            assert_eq!(
                gateway.direct_opens.load(Ordering::SeqCst),
                index + 1,
                "{path}"
            );
            assert!(!dest.exists());
        }
        assert!(!gateway.minted.load(Ordering::SeqCst));
        server.abort();
    }
}
