// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Servers on the test host that sandboxes reach through
//! `host.openshell.internal`, and that record what arrived, so a test can
//! check what the supervisor forwarded upstream.
//!
//! The servers listen on every host address, IPv6 and IPv4, since drivers map
//! `host.openshell.internal` to different ones, and stop when dropped. They
//! listen on IPv4 only where the host has no IPv6. They run where the tests
//! run, so a gateway whose sandboxes can't reach the test host, such as one
//! on a remote cluster, can't run tests that use them.
//!
//! - [`HttpRecorder`] answers HTTP requests with a fixed body or a handler's
//!   [`Response`], and records each parsed [`Request`]. It serves HTTPS with
//!   a certificate from a [`TestCa`], and listens on a random free port unless
//!   [`HttpRecorder::builder`] names one.
//! - [`WebSocketRecorder`] completes the WebSocket handshake and records the
//!   frames that arrive.
//! - [`TcpServer`] records raw bytes, and echoes them or answers once the
//!   client goes idle.
//! - [`free_port`] finds a port nothing listens on, and [`exchange`] sends
//!   bytes to a loopback port and reads the reply.

mod http;
mod tcp;
mod tls;
mod websocket;

use std::io::ErrorKind;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use socket2::{Domain, Protocol, Socket, Type};
use testkit::sdk::raw::proto;
use testkit::{PYTHON_BINARIES, Result, ResultExt as _, policy};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

pub use http::{HttpRecorder, HttpRecorderBuilder, Request, Response};
pub use tcp::{TcpServer, exchange};
pub use tls::{ADDITIONAL_CA_CERT_ENV, ADDITIONAL_CA_KEY_ENV, Identity, TestCa};
pub use websocket::{TEXT_REPLY, WebSocketRecorder};

/// The name a sandbox reaches these servers by.
pub const TEST_HOST: &str = "host.openshell.internal";

/// Let [`PYTHON_BINARIES`] reach a server on the test host at `port` under
/// the network policy `name`; see [`policy::allow`].
pub fn allow_host<'a>(
    policy: &'a mut proto::SandboxPolicy,
    name: &str,
    port: u16,
) -> &'a mut proto::NetworkEndpoint {
    policy::allow(policy, name, TEST_HOST, port, PYTHON_BINARIES)
}

const WAIT_TIMEOUT: Duration = Duration::from_secs(10);
const WAIT_INTERVAL: Duration = Duration::from_millis(100);
const READ_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_REQUEST: usize = 1024 * 1024;

/// Listen on every IPv6 and IPv4 host address at `port`, or on IPv4 only
/// where the host has no IPv6. Port 0 picks a random free port.
async fn bind(port: u16) -> Result<(TcpListener, u16)> {
    let listener = match bind_dual_stack(port) {
        Err(error)
            if matches!(
                error.kind(),
                ErrorKind::AddrNotAvailable | ErrorKind::Unsupported
            ) =>
        {
            TcpListener::bind((Ipv4Addr::UNSPECIFIED, port)).await
        }
        result => result,
    }
    .context(if port == 0 {
        "bind a host server".to_string()
    } else {
        format!("bind a host server on port {port}")
    })?;
    let port = listener
        .local_addr()
        .context("read the host server's address")?
        .port();
    Ok((listener, port))
}

/// An IPv6 listener that also accepts IPv4, whatever the host's default.
fn bind_dual_stack(port: u16) -> std::io::Result<TcpListener> {
    let socket = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_only_v6(false)?;
    // As tokio's own bind does.
    #[cfg(unix)]
    socket.set_reuse_address(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&SocketAddr::from((Ipv6Addr::UNSPECIFIED, port)).into())?;
    socket.listen(1024)?;
    TcpListener::from_std(socket.into())
}

/// An accept loop on a new port that hands each connection to its own task,
/// counts the connections, and stops when dropped.
struct Server {
    port: u16,
    connections: Arc<AtomicUsize>,
    task: JoinHandle<()>,
}

impl Server {
    async fn start<F, Fut>(port: u16, serve: F) -> Result<Self>
    where
        F: Fn(TcpStream) -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let (listener, port) = bind(port).await?;
        let connections = Arc::new(AtomicUsize::new(0));
        let task_connections = Arc::clone(&connections);
        let task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                task_connections.fetch_add(1, Ordering::AcqRel);
                tokio::spawn(serve(stream));
            }
        });
        Ok(Self {
            port,
            connections,
            task,
        })
    }

    fn connections(&self) -> usize {
        self.connections.load(Ordering::Acquire)
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// A port that nothing on the test host listened on when this returned.
pub async fn free_port() -> Result<u16> {
    let (_listener, port) = bind(0).await?;
    Ok(port)
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn header(head: &str, name: &str) -> Option<String> {
    head.lines().find_map(|line| {
        let (header, value) = line.split_once(':')?;
        header
            .trim()
            .eq_ignore_ascii_case(name)
            .then(|| value.trim().to_string())
    })
}
