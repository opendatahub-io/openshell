// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Hand the proxy the selected gateway and SSH route over private IPC. The
//! issuer retains any legacy session grant until admission or cancellation.

#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;
#[cfg(unix)]
use unix as ipc;
#[cfg(windows)]
use windows as ipc;

use crate::forward::{
    SandboxProxyCommand, build_proxy_command, supports_direct_ssh, validate_ssh_sandbox_id,
    validate_ssh_session_response,
};
use crate::metadata::ObjectId;
use crate::proto::{
    CreateSshSessionRequest, CreateSshSessionResponse, GetSandboxRequest, RevokeSshSessionRequest,
    Sandbox, SandboxResponse, open_shell_client::OpenShellClient, workspace_selector,
};
use crate::replica_routing::{owner_replica, with_owner_hint};
use crate::ssh_host_key::{HostKeyCheck, SandboxSshTarget};
use crate::time::{duration_from_std, duration_to_std};
use miette::{IntoDiagnostic, Result};
use prost::Message;
use std::{borrow::Cow, future::Future, time::Duration};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::oneshot;
use tonic::{
    service::{Interceptor, interceptor::InterceptedService},
    transport::Channel,
};
use uuid::Uuid;

type Client<I> = OpenShellClient<InterceptedService<Channel, I>>;

// Room for a unary session response plus the endpoint, profile and routing hint.
const MAX_HANDOFF_SIZE: usize = 5 * 1024 * 1024;
/// The gateway refused direct admission. End this operation, including automatic recovery.
pub const DIRECT_SSH_REFUSED: u8 = 2;

#[derive(Debug, thiserror::Error, miette::Diagnostic)]
pub enum SshAdmissionError {
    #[error("{0}")]
    Rpc(tonic::Status),
    #[error("gateway refused direct SSH admission")]
    Refused,
    #[error("sandbox was replaced before opening the SSH relay")]
    Replaced,
    #[error("gateway stopped advertising direct SSH")]
    CapabilityLost,
}

impl SshAdmissionError {
    pub fn is_retryable(&self) -> bool {
        let Self::Rpc(status) = self else {
            return false;
        };
        match status.code() {
            tonic::Code::Unavailable | tonic::Code::DeadlineExceeded => true,
            tonic::Code::Unknown | tonic::Code::Internal | tonic::Code::Cancelled => {
                std::error::Error::source(status)
                    .is_some_and(crate::transport_errors::is_expected_transport_close_error)
            }
            _ => false,
        }
    }
}

#[derive(Clone, Debug)]
pub struct SshTarget {
    pub endpoint: String,
    pub gateway_name: String,
    pub name: String,
    pub workspace: String,
    pub id: String,
    /// Capability from the selected sandbox's `GetSandbox` reply. Look it up if unknown.
    pub direct_ssh: Option<bool>,
    /// SSH host key fingerprint from the same reply. Empty when the gateway
    /// published none.
    pub host_key_fingerprint: String,
    pub replica: Option<String>,
    pub gateway_insecure: bool,
    pub cleanup: SshCleanup,
}

#[derive(Message)]
pub struct RelayGrant {
    #[prost(oneof = "RelayAuthorization", tags = "1, 5")]
    pub authorization: Option<RelayAuthorization>,
    #[prost(string, tag = "2")]
    pub endpoint: String,
    #[prost(string, tag = "3")]
    pub gateway_name: String,
    #[prost(string, optional, tag = "4")]
    pub replica: Option<String>,
    /// Absent when the issuer predates host-key verification.
    #[prost(message, optional, tag = "6")]
    pub host_key: Option<HostKeyHandoff>,
}

/// The host key the proxy must see, and the file in which it pins that key
/// for the issuer's `ssh`.
#[derive(Message)]
pub struct HostKeyHandoff {
    /// A fingerprint, or `unverified`.
    #[prost(string, tag = "1")]
    pub expectation: String,
    #[prost(string, tag = "2")]
    pub known_hosts: String,
}

#[derive(prost::Oneof)]
pub enum RelayAuthorization {
    #[prost(message, tag = "1")]
    Session(CreateSshSessionResponse),
    #[prost(message, tag = "5")]
    Direct(DirectSshRelay),
}

#[derive(Message)]
pub struct DirectSshRelay {
    #[prost(string, tag = "1")]
    pub sandbox_id: String,
    #[prost(bool, tag = "2")]
    pub gateway_insecure: bool,
    #[prost(message, optional, tag = "3")]
    pub registration_timeout: Option<prost_types::Duration>,
}

impl DirectSshRelay {
    pub fn registration_timeout(&self) -> Result<Option<Duration>> {
        self.registration_timeout
            .as_ref()
            .map(duration_to_std)
            .transpose()
            .into_diagnostic()
    }
}

impl RelayGrant {
    fn validate(&self) -> Result<&str> {
        match &self.authorization {
            Some(RelayAuthorization::Session(session)) => {
                validate_ssh_session_response(session).map_err(|err| {
                    miette::miette!("gateway returned invalid SSH session response: {err}")
                })?;
                Ok(&session.sandbox_id)
            }
            Some(RelayAuthorization::Direct(direct)) => {
                validate_ssh_sandbox_id(&direct.sandbox_id).into_diagnostic()?;
                direct.registration_timeout()?;
                Ok(&direct.sandbox_id)
            }
            None => Err(miette::miette!("missing SSH handoff authorization")),
        }
    }
}

pub struct PreparedProxy {
    command: SandboxProxyCommand,
    cancel: oneshot::Sender<()>,
    cleanup: tokio::task::JoinHandle<Result<Option<Duration>>>,
}

/// Work that must finish before an SSH command or TUI releases its runtime.
#[derive(Clone, Debug, Default)]
pub struct SshCleanup(tokio_util::task::TaskTracker);

impl SshCleanup {
    pub fn spawn<T: Send + 'static>(
        &self,
        future: impl Future<Output = T> + Send + 'static,
    ) -> tokio::task::JoinHandle<T> {
        self.0.spawn(future)
    }

    pub async fn drain(&self) {
        self.0.close();
        self.0.wait().await;
    }
}

impl SshTarget {
    pub fn new(endpoint: &str, gateway_name: &str, name: &str, workspace: &str, id: &str) -> Self {
        Self {
            endpoint: endpoint.into(),
            gateway_name: gateway_name.into(),
            name: name.into(),
            workspace: workspace.into(),
            id: id.into(),
            direct_ssh: None,
            host_key_fingerprint: String::new(),
            replica: None,
            gateway_insecure: false,
            cleanup: SshCleanup::default(),
        }
    }

    pub fn lookup_request(&self) -> tonic::Request<GetSandboxRequest> {
        with_owner_hint(GetSandboxRequest {
            name: self.name.clone(),
            workspace_scope: Some(workspace_selector(self.workspace.clone())),
        })
    }

    pub fn observe_lookup<'a>(
        &mut self,
        response: &'a tonic::Response<SandboxResponse>,
    ) -> Result<&'a Sandbox> {
        let sandbox = response
            .get_ref()
            .sandbox
            .as_ref()
            .ok_or_else(|| miette::miette!("sandbox not found"))?;
        if sandbox.object_id() != self.id {
            return Err(SshAdmissionError::Replaced.into());
        }
        let advertised = supports_direct_ssh(response)?;
        if self.direct_ssh == Some(true) && !advertised {
            return Err(SshAdmissionError::CapabilityLost.into());
        }
        self.direct_ssh = Some(advertised);
        self.host_key_fingerprint
            .clone_from(&sandbox.host_key_fingerprint);
        self.replica =
            owner_replica(response).and_then(|owner| owner.to_str().ok().map(str::to_owned));
        Ok(sandbox)
    }

    pub async fn prepare<I: Interceptor + Clone + Send + Sync + 'static>(
        &self,
        mut client: Client<I>,
        registration_timeout: Option<Duration>,
    ) -> Result<PreparedProxy> {
        let mut target = Cow::Borrowed(self);
        if target.direct_ssh.is_none() {
            let response = client
                .get_sandbox(target.lookup_request())
                .await
                .map_err(SshAdmissionError::Rpc)?;
            target.to_mut().observe_lookup(&response)?;
        }
        // Before any session is created, so that a refusal leaves no grant.
        let host_key = HostKeyCheck::for_target(
            &target.host_key_fingerprint,
            &SandboxSshTarget {
                gateway: &self.gateway_name,
                workspace: &self.workspace,
                sandbox: &self.name,
            },
        )
        .into_diagnostic()?;
        let authorization = if target.direct_ssh == Some(true) {
            RelayAuthorization::Direct(DirectSshRelay {
                sandbox_id: target.id.clone(),
                gateway_insecure: target.gateway_insecure,
                registration_timeout: registration_timeout
                    .map(duration_from_std)
                    .transpose()
                    .into_diagnostic()?,
            })
        } else {
            let request = CreateSshSessionRequest {
                sandbox: self.name.clone(),
                workspace_scope: Some(workspace_selector(self.workspace.clone())),
            };
            let started = tokio::time::Instant::now();
            let session = loop {
                match client.create_ssh_session(request.clone()).await {
                    Ok(response) => break response.into_inner(),
                    Err(status)
                        if status.code() == tonic::Code::FailedPrecondition
                            && registration_timeout
                                .is_some_and(|timeout| started.elapsed() < timeout) =>
                    {
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                    Err(status) => return Err(SshAdmissionError::Rpc(status).into()),
                }
            };
            RelayAuthorization::Session(session)
        };
        let revoke = match &authorization {
            RelayAuthorization::Session(session) => {
                Some(revoke_grant(client, session.token.clone()))
            }
            RelayAuthorization::Direct(_) => None,
        };
        let grant = RelayGrant {
            authorization: Some(authorization),
            endpoint: target.endpoint.clone(),
            gateway_name: target.gateway_name.clone(),
            replica: target.replica.clone(),
            host_key: Some(host_key.handoff()),
        };
        let setup = || {
            if grant.validate()? != self.id {
                return Err(SshAdmissionError::Replaced.into());
            }
            if grant.encoded_len() > MAX_HANDOFF_SIZE {
                return Err(miette::miette!("SSH handoff exceeds the size limit"));
            }
            let id = Uuid::new_v4();
            let listener = ipc::Listener::bind(id).into_diagnostic()?;
            let handle = format!("{}-{id}", std::process::id());
            let exe = std::env::current_exe().into_diagnostic()?;
            let command =
                build_proxy_command(&exe.to_string_lossy(), &handle, &self.name, &self.workspace);
            Ok((listener, command))
        };
        let (listener, command) = match setup() {
            Ok(parts) => parts,
            Err(error) => {
                if let Some(revoke) = revoke {
                    self.cleanup.spawn(revoke).await.into_diagnostic()?;
                }
                return Err(error);
            }
        };
        let payload = grant.encode_to_vec();
        let (cancel, mut cancelled) = oneshot::channel();
        let cleanup = self.cleanup.spawn(async move {
            let direct = revoke.is_none();
            let serve = async {
                let mut peer = listener.accept().await?;
                peer.write_u32(u32::try_from(payload.len()).map_err(std::io::Error::other)?)
                    .await?;
                peer.write_all(&payload).await?;
                let reply = peer.read_u8().await?;
                if reply != 1 && (reply != DIRECT_SSH_REFUSED || !direct) {
                    return Err(std::io::ErrorKind::InvalidData.into());
                }
                Ok::<_, std::io::Error>((peer, reply))
            };
            // Keep the peer until the issuing client has attempted revocation.
            let peer = tokio::select! {
                result = serve => result.ok(),
                _ = &mut cancelled => None,
            };
            let started = std::time::Instant::now();
            if let Some(revoke) = revoke {
                revoke.await;
            }
            if let Some((mut peer, reply)) = peer {
                let _ = peer.write_u8(1).await;
                let handshake_wait = started.elapsed();
                if reply == DIRECT_SSH_REFUSED {
                    return Err(SshAdmissionError::Refused.into());
                }
                if direct {
                    // gRPC can deliver a refusal in trailers after sending response headers.
                    tokio::select! {
                        biased;
                        status = peer.read_u8() => {
                            if matches!(status, Ok(DIRECT_SSH_REFUSED)) {
                                let _ = peer.write_u8(1).await;
                                return Err(SshAdmissionError::Refused.into());
                            }
                        }
                        _ = cancelled => {}
                    }
                }
                Ok(Some(handshake_wait))
            } else {
                Ok(None)
            }
        });
        Ok(PreparedProxy {
            command: SandboxProxyCommand::new(command, host_key),
            cancel,
            cleanup,
        })
    }
}

pub async fn revoke_grant<I: Interceptor + Clone>(mut client: Client<I>, token: String) {
    let request = RevokeSshSessionRequest {
        token,
        allow_missing: true,
    };
    if !matches!(
        tokio::time::timeout(Duration::from_secs(2), client.revoke_ssh_session(request)).await,
        Ok(Ok(_))
    ) {
        eprintln!("Warning: could not revoke the SSH session token");
    }
}

impl PreparedProxy {
    pub fn command(&self) -> &SandboxProxyCommand {
        &self.command
    }

    pub async fn run<T>(self, operation: impl Future<Output = Result<T>>) -> Result<T> {
        self.run_with_admission(operation)
            .await
            .map(|(value, _)| value)
    }

    /// Return the time an admitted proxy spent waiting for any legacy revocation
    /// so callers can exclude it from time attached to the sandbox.
    pub async fn run_with_admission<T>(
        self,
        operation: impl Future<Output = Result<T>>,
    ) -> Result<(T, Option<Duration>)> {
        let result = operation.await;
        drop(self.cancel);
        let revocation_wait = self.cleanup.await.into_diagnostic()??;
        Ok((result?, revocation_wait))
    }
}

pub async fn receive(handle: &str) -> Result<(RelayGrant, impl AsyncRead + AsyncWrite + Unpin)> {
    let (pid, id) = handle
        .split_once('-')
        .ok_or_else(|| miette::miette!("invalid SSH handoff"))?;
    let pid = pid.parse::<u32>().into_diagnostic()?;
    let id = Uuid::parse_str(id).into_diagnostic()?;
    #[cfg(unix)]
    let mut peer = ipc::connect(id, pid).await.into_diagnostic()?;
    #[cfg(windows)]
    let mut peer = ipc::connect(id, pid).into_diagnostic()?;
    let size = peer.read_u32().await.into_diagnostic()? as usize;
    if size > MAX_HANDOFF_SIZE {
        return Err(miette::miette!("SSH handoff exceeds the size limit"));
    }
    let mut payload = vec![0; size];
    peer.read_exact(&mut payload).await.into_diagnostic()?;
    let grant = RelayGrant::decode(&payload[..])
        .map_err(|_| miette::miette!("invalid SSH handoff message"))?;
    grant.validate()?;
    Ok((grant, peer))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_environment::{Environment, fixture_dir};

    #[test]
    fn transport_loss_requires_a_local_cause_for_ambiguous_statuses() {
        let reset = std::io::Error::from(std::io::ErrorKind::ConnectionReset);
        let local = tonic::Status::from_error(Box::new(reset));
        assert_eq!(local.code(), tonic::Code::Unknown);
        assert!(SshAdmissionError::Rpc(local).is_retryable());
        for code in [
            tonic::Code::Unknown,
            tonic::Code::Internal,
            tonic::Code::Cancelled,
            tonic::Code::PermissionDenied,
        ] {
            let remote = tonic::Status::new(code, "connection reset");
            assert!(!SshAdmissionError::Rpc(remote).is_retryable());
        }
    }

    #[test]
    fn a_replacement_cannot_authorize_the_selected_target() {
        let mut target = SshTarget::new("endpoint", "gateway", "box", "team", "original");
        let mut response = tonic::Response::new(SandboxResponse {
            sandbox: Some(Sandbox {
                metadata: Some(crate::proto::datamodel::v1::ObjectMeta {
                    id: "replacement".into(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        });
        response
            .metadata_mut()
            .insert(crate::forward::DIRECT_SSH_HEADER, "1".parse().unwrap());
        assert!(target.observe_lookup(&response).is_err());
        assert_eq!(target.direct_ssh, None);
    }

    const FINGERPRINT: &str = "SHA256:ZkAslGjFiUHdGf/WUL8rQvkib4PTvQatUV0OUQSncCA";

    fn direct_target(endpoint: &str) -> SshTarget {
        let mut target = SshTarget::new(endpoint, "gateway", "box", "team", "id-1");
        target.direct_ssh = Some(true);
        target.host_key_fingerprint = FINGERPRINT.into();
        target
    }

    fn no_rpc_client(
        endpoint: &'static str,
    ) -> Client<impl Interceptor + Clone + Send + Sync + 'static> {
        OpenShellClient::with_interceptor(Channel::from_static(endpoint).connect_lazy(), |_| {
            panic!("the handoff issued an unexpected gateway RPC")
        })
    }

    #[tokio::test]
    async fn direct_handoff_observes_admission_without_session_rpcs() {
        let config_home = fixture_dir().unwrap();
        let known_hosts = config_home
            .path()
            .join("openshell/known_hosts/gateway/openshell-box.team");
        Environment::new()
            .set("XDG_CONFIG_HOME", config_home.path())
            .run_async(async {
                let endpoint = "http://127.0.0.1:0";
                let client = no_rpc_client(endpoint);
                let mut target = direct_target(endpoint);
                target.gateway_insecure = true;
                target.replica = Some("owner".into());

                let timeout = Duration::from_nanos(2_500_003);
                let proxy = target.prepare(client.clone(), Some(timeout)).await.unwrap();
                let handle = proxy
                    .command()
                    .as_str()
                    .rsplit_once(' ')
                    .unwrap()
                    .1
                    .to_owned();
                let ((), admitted) = proxy
                    .run_with_admission(async {
                        let (grant, mut peer) = receive(&handle).await?;
                        let Some(RelayAuthorization::Direct(direct)) = grant.authorization else {
                            panic!("missing direct SSH target");
                        };
                        assert_eq!(direct.sandbox_id, "id-1");
                        assert!(direct.gateway_insecure);
                        assert_eq!(direct.registration_timeout()?, Some(timeout));
                        assert_eq!(grant.endpoint, endpoint);
                        assert_eq!(grant.gateway_name, "gateway");
                        assert_eq!(grant.replica.as_deref(), Some("owner"));
                        let host_key = grant.host_key.unwrap();
                        assert_eq!(host_key.expectation, FINGERPRINT);
                        assert_eq!(std::path::Path::new(&host_key.known_hosts), known_hosts);
                        peer.write_u8(1).await.into_diagnostic()?;
                        assert_eq!(peer.read_u8().await.into_diagnostic()?, 1);
                        Ok(())
                    })
                    .await
                    .unwrap();
                assert!(admitted.is_some());

                let proxy = target.prepare(client, None).await.unwrap();
                let ((), admitted) = proxy.run_with_admission(async { Ok(()) }).await.unwrap();
                assert!(admitted.is_none());
            })
            .await;
    }

    #[tokio::test]
    async fn a_sandbox_with_no_published_host_key_gets_no_proxy() {
        let config_home = fixture_dir().unwrap();
        Environment::new()
            .set("XDG_CONFIG_HOME", config_home.path())
            .remove(crate::ssh_host_key::REQUIRE_HOST_KEY_ENV)
            .run_async(async {
                let endpoint = "http://127.0.0.1:0";
                // A session grant: it must not be created and left behind.
                let mut target = SshTarget::new(endpoint, "gateway", "box", "team", "id-1");
                target.direct_ssh = Some(false);

                let Err(refusal) = target.prepare(no_rpc_client(endpoint), None).await else {
                    panic!("prepared a proxy for an unverified sandbox")
                };

                assert!(
                    refusal.to_string().starts_with("SSH refused: "),
                    "{refusal}"
                );
            })
            .await;
    }

    #[tokio::test]
    async fn proxy_rejects_a_different_issuer_pid_before_reading_a_grant() {
        let id = Uuid::new_v4();
        let listener = ipc::Listener::bind(id).unwrap();
        let handle = format!("{}-{id}", std::process::id() + 1);
        // Leave the server alive without writing a frame. A client that trusts
        // the handle alone would hang waiting for credentials.
        let result = tokio::time::timeout(Duration::from_secs(2), receive(&handle))
            .await
            .unwrap();
        let Err(error) = result else {
            panic!("accepted an unrelated issuer")
        };
        assert!(
            error
                .to_string()
                .contains(&std::io::Error::from(std::io::ErrorKind::PermissionDenied).to_string())
        );
        drop(listener);
    }
}
