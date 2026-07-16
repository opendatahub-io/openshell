// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Upstream corporate proxy chaining for the sandbox egress proxy.
//!
//! In proxy-required enterprise networks (issue #1792) the supervisor cannot
//! dial policy-approved destinations directly: all outbound traffic must go
//! through a corporate forward proxy. This module reads the operator-owned
//! reserved `OPENSHELL_UPSTREAM_HTTPS_PROXY` / `OPENSHELL_UPSTREAM_HTTP_PROXY`
//! / `OPENSHELL_UPSTREAM_NO_PROXY` variables from the supervisor's **own**
//! environment and chains approved connections through the corporate proxy
//! with HTTP CONNECT.
//!
//! The conventional `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` / `NO_PROXY`
//! variables are intentionally ignored: those are controlled by the sandbox
//! creator and are rewritten separately to point the workload child at the
//! local policy proxy, so honoring them would let a sandbox pick an arbitrary
//! upstream proxy or disable proxying with `NO_PROXY=*`. The compute driver
//! writes the reserved names in its required-variable tier, which sandbox and
//! template environment cannot override.
//!
//! Scope and invariants:
//! - Only `http://` proxy URLs are supported. `https://` and SOCKS proxies
//!   are ignored with a warning.
//! - Policy evaluation, DNS resolution, and SSRF checks run exactly as in the
//!   direct-dial path; the corporate proxy only replaces the final TCP dial.
//! - The reserved `NO_PROXY` list decides which destinations bypass the
//!   corporate proxy and keep dialing directly (cluster-internal services,
//!   host gateway, etc.). Loopback destinations always bypass the proxy.

use std::io::{Error as IoError, ErrorKind};
use std::net::IpAddr;
use std::time::Duration;

use base64::Engine as _;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{debug, warn};

/// Upper bound on the corporate proxy's CONNECT response header block.
const MAX_CONNECT_RESPONSE_BYTES: usize = 8 * 1024;

/// End-to-end budget for dialing the corporate proxy and completing the
/// CONNECT handshake.
const CONNECT_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);

/// Which proxy variable applies to a destination.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpstreamScheme {
    /// TLS-bound tunnels (client issued CONNECT): `HTTPS_PROXY`.
    Https,
    /// Plain HTTP forward-proxy requests: `HTTP_PROXY`.
    Http,
}

/// A parsed corporate proxy endpoint.
#[derive(Clone)]
pub struct ProxyEndpoint {
    host: String,
    port: u16,
    /// Pre-computed `Basic <base64>` header value from the proxy auth file.
    /// Never logged.
    proxy_authorization: Option<String>,
}

impl ProxyEndpoint {
    /// `host:port` label for logs. Excludes credentials.
    #[must_use]
    pub fn display_addr(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

impl std::fmt::Debug for ProxyEndpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProxyEndpoint")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("proxy_authorization", &self.proxy_authorization.is_some())
            .finish()
    }
}

/// One parsed `NO_PROXY` entry.
#[derive(Debug, Clone)]
enum NoProxyEntry {
    /// `*` — bypass the proxy for every destination.
    Wildcard,
    /// Domain suffix match: `corp.com` matches `corp.com` and `x.corp.com`.
    Domain(String),
    /// Exact IP literal match.
    Ip(IpAddr),
    /// CIDR match against IP-literal destination hosts.
    Cidr(ipnet::IpNet),
}

/// Parsed `NO_PROXY` list.
#[derive(Debug, Clone, Default)]
struct NoProxy {
    entries: Vec<NoProxyEntry>,
}

impl NoProxy {
    fn parse(raw: &str) -> Self {
        let mut entries = Vec::new();
        for item in raw.split(',') {
            let item = item.trim();
            if item.is_empty() {
                continue;
            }
            if item == "*" {
                entries.push(NoProxyEntry::Wildcard);
                continue;
            }
            if let Ok(net) = item.parse::<ipnet::IpNet>() {
                entries.push(NoProxyEntry::Cidr(net));
                continue;
            }
            if let Ok(ip) = item.trim_matches(['[', ']']).parse::<IpAddr>() {
                entries.push(NoProxyEntry::Ip(ip));
                continue;
            }
            // Domain entry. Strip a `:port` qualifier (ports are ignored),
            // then any leading `*.` or `.` so `.corp.com`, `*.corp.com`, and
            // `corp.com` all behave identically.
            let name = item.rsplit_once(':').map_or(item, |(name, port)| {
                if port.chars().all(|c| c.is_ascii_digit()) {
                    name
                } else {
                    item
                }
            });
            let name = name
                .strip_prefix("*.")
                .or_else(|| name.strip_prefix('.'))
                .unwrap_or(name)
                .to_ascii_lowercase();
            if !name.is_empty() {
                entries.push(NoProxyEntry::Domain(name));
            }
        }
        Self { entries }
    }

    /// Whether `host` (lowercase hostname or IP literal) must bypass the
    /// corporate proxy. Loopback destinations always match.
    fn matches(&self, host: &str) -> bool {
        let host_ip = host.trim_matches(['[', ']']).parse::<IpAddr>().ok();
        if host == "localhost" || host_ip.is_some_and(|ip| ip.is_loopback()) {
            return true;
        }
        self.entries.iter().any(|entry| match entry {
            NoProxyEntry::Wildcard => true,
            NoProxyEntry::Domain(suffix) => {
                host == suffix
                    || host
                        .strip_suffix(suffix)
                        .is_some_and(|prefix| prefix.ends_with('.'))
            }
            NoProxyEntry::Ip(ip) => host_ip == Some(*ip),
            NoProxyEntry::Cidr(net) => host_ip.is_some_and(|ip| net.contains(&ip)),
        })
    }
}

/// Corporate proxy configuration read from the supervisor's environment.
#[derive(Debug, Clone)]
pub struct UpstreamProxyConfig {
    https: Option<ProxyEndpoint>,
    http: Option<ProxyEndpoint>,
    no_proxy: NoProxy,
}

impl UpstreamProxyConfig {
    /// Read the operator-owned corporate proxy configuration from the
    /// supervisor's reserved environment variables
    /// ([`UPSTREAM_HTTPS_PROXY`](openshell_core::sandbox_env::UPSTREAM_HTTPS_PROXY),
    /// [`UPSTREAM_HTTP_PROXY`](openshell_core::sandbox_env::UPSTREAM_HTTP_PROXY),
    /// [`UPSTREAM_NO_PROXY`](openshell_core::sandbox_env::UPSTREAM_NO_PROXY)).
    /// Returns `None` when no usable proxy is configured.
    ///
    /// The conventional `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` / `NO_PROXY`
    /// variables are intentionally ignored here: they are set by the sandbox
    /// creator (and rewritten to point workload children at the local policy
    /// proxy), so honoring them would let a sandbox choose an arbitrary
    /// upstream proxy or disable proxying entirely. The compute driver writes
    /// the reserved names in its required-variable tier, where sandbox and
    /// template environment cannot override them.
    #[must_use]
    pub fn from_env() -> Option<Self> {
        let mut config = Self::from_lookup(|name| std::env::var(name).ok())?;

        // Load proxy credentials from the reserved auth file, if configured,
        // and apply them to every endpoint. The file is delivered through a
        // root-only secret mount so the credentials never appear in the
        // environment or container metadata.
        if let Some(path) = std::env::var(openshell_core::sandbox_env::UPSTREAM_PROXY_AUTH_FILE)
            .ok()
            .filter(|p| !p.trim().is_empty())
        {
            match std::fs::read_to_string(&path) {
                Ok(credential) => config.apply_proxy_auth(basic_auth_header(&credential)),
                Err(err) => warn!(
                    "failed to read upstream proxy auth file '{path}': {err}; \
                     proceeding without proxy credentials"
                ),
            }
        }

        Some(config)
    }

    fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Option<Self> {
        use openshell_core::sandbox_env::{
            UPSTREAM_HTTP_PROXY, UPSTREAM_HTTPS_PROXY, UPSTREAM_NO_PROXY,
        };
        let var = |name: &str| lookup(name).filter(|v| !v.trim().is_empty());
        let https =
            var(UPSTREAM_HTTPS_PROXY).and_then(|url| parse_proxy_url(&url, UPSTREAM_HTTPS_PROXY));
        let http =
            var(UPSTREAM_HTTP_PROXY).and_then(|url| parse_proxy_url(&url, UPSTREAM_HTTP_PROXY));
        if https.is_none() && http.is_none() {
            return None;
        }
        let no_proxy = NoProxy::parse(&var(UPSTREAM_NO_PROXY).unwrap_or_default());
        Some(Self {
            https,
            http,
            no_proxy,
        })
    }

    /// Attach a pre-built `Proxy-Authorization` header value to every
    /// configured endpoint. A `None` value clears any existing credentials.
    fn apply_proxy_auth(&mut self, proxy_authorization: Option<String>) {
        for endpoint in [self.https.as_mut(), self.http.as_mut()]
            .into_iter()
            .flatten()
        {
            endpoint
                .proxy_authorization
                .clone_from(&proxy_authorization);
        }
    }

    /// The corporate proxy to use for `host`, or `None` when the destination
    /// must be dialed directly.
    #[must_use]
    pub fn proxy_for(&self, scheme: UpstreamScheme, host: &str) -> Option<&ProxyEndpoint> {
        if self.no_proxy.matches(host) {
            return None;
        }
        match scheme {
            UpstreamScheme::Https => self.https.as_ref(),
            UpstreamScheme::Http => self.http.as_ref(),
        }
    }

    /// Credential-free summary for startup logging.
    #[must_use]
    pub fn summary(&self) -> String {
        let fmt = |ep: Option<&ProxyEndpoint>| {
            ep.map_or_else(|| "-".to_string(), ProxyEndpoint::display_addr)
        };
        format!(
            "https_proxy={} http_proxy={} no_proxy_entries={}",
            fmt(self.https.as_ref()),
            fmt(self.http.as_ref()),
            self.no_proxy.entries.len()
        )
    }
}

/// Parse an `http://host[:port]` proxy URL. Unsupported schemes (TLS or SOCKS
/// proxies) are rejected with a warning.
///
/// Credentials are never taken from the URL: they are delivered out of band
/// through [`UPSTREAM_PROXY_AUTH_FILE`](openshell_core::sandbox_env::UPSTREAM_PROXY_AUTH_FILE)
/// so they never appear in config or container metadata. Any `user:pass@`
/// userinfo present in the URL is ignored with a warning.
fn parse_proxy_url(raw: &str, var_name: &str) -> Option<ProxyEndpoint> {
    let raw = raw.trim();
    let rest = match raw.split_once("://") {
        Some((scheme, rest)) => {
            if !scheme.eq_ignore_ascii_case("http") {
                warn!(
                    "{var_name} uses unsupported proxy scheme '{scheme}' \
                     (only http:// proxies are supported); ignoring"
                );
                return None;
            }
            rest
        }
        None => raw,
    };
    // Drop any path component.
    let rest = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let authority = match rest.rsplit_once('@') {
        Some((_userinfo, authority)) => {
            warn!(
                "{var_name} contains inline credentials, which are ignored; \
                 supply proxy credentials via the proxy auth file"
            );
            authority
        }
        None => rest,
    };
    let Some((host, port)) = split_host_port(authority) else {
        warn!("{var_name} has an invalid proxy address '{authority}'; ignoring");
        return None;
    };
    Some(ProxyEndpoint {
        host,
        port,
        proxy_authorization: None,
    })
}

/// Split `host[:port]` (with optional `[v6]` brackets), defaulting to port 80.
fn split_host_port(authority: &str) -> Option<(String, u16)> {
    if authority.is_empty() {
        return None;
    }
    if let Some(v6_end) = authority.find(']') {
        if !authority.starts_with('[') {
            return None;
        }
        let host = authority[1..v6_end].to_string();
        let port = match authority[v6_end + 1..].strip_prefix(':') {
            Some(port) => port.parse().ok()?,
            None if authority[v6_end + 1..].is_empty() => 80,
            None => return None,
        };
        return Some((host, port));
    }
    match authority.rsplit_once(':') {
        Some((host, port)) if !host.contains(':') => Some((host.to_string(), port.parse().ok()?)),
        Some(_) => None, // bare IPv6 without brackets is ambiguous
        None => Some((authority.to_string(), 80)),
    }
}

/// Build a `Proxy-Authorization: Basic <base64>` header value from a raw
/// `user:pass` credential.
///
/// Returns `None` for an empty credential or one containing control characters
/// (CR, LF, NUL) that could inject additional HTTP headers. The credential is
/// used verbatim: it is delivered through a trusted operator file, not a URL,
/// so there is no percent-encoding to decode.
fn basic_auth_header(credential: &str) -> Option<String> {
    let credential = credential.trim();
    if credential.is_empty() || credential.contains(|c: char| c.is_control()) {
        return None;
    }
    Some(format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(credential)
    ))
}

/// Open a tunnel to `host:port` through the corporate proxy with HTTP CONNECT.
///
/// Returns the connected stream once the proxy answers 200; after that the
/// stream is a transparent byte pipe to the destination.
///
/// The destination hostname (not a locally resolved IP) is sent in the
/// CONNECT target so hostname-filtering proxies keep working; local DNS
/// resolution and SSRF validation must already have happened at the call
/// site.
///
/// # Errors
///
/// Returns an error when the proxy is unreachable, the handshake times out,
/// or the proxy answers with a non-200 status.
pub async fn connect_via(
    endpoint: &ProxyEndpoint,
    host: &str,
    port: u16,
) -> std::io::Result<TcpStream> {
    tokio::time::timeout(
        CONNECT_HANDSHAKE_TIMEOUT,
        connect_via_inner(endpoint, host, port),
    )
    .await
    .map_err(|_| {
        IoError::new(
            ErrorKind::TimedOut,
            format!(
                "upstream proxy {} CONNECT handshake timed out",
                endpoint.display_addr()
            ),
        )
    })?
}

async fn connect_via_inner(
    endpoint: &ProxyEndpoint,
    host: &str,
    port: u16,
) -> std::io::Result<TcpStream> {
    let mut stream = TcpStream::connect((endpoint.host.as_str(), endpoint.port)).await?;

    let target = if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    let mut request = format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n");
    if let Some(auth) = &endpoint.proxy_authorization {
        request.push_str("Proxy-Authorization: ");
        request.push_str(auth);
        request.push_str("\r\n");
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).await?;

    // Read the proxy's response header block.
    let mut buf = vec![0u8; MAX_CONNECT_RESPONSE_BYTES];
    let mut used = 0;
    loop {
        if used == buf.len() {
            return Err(IoError::other(format!(
                "upstream proxy {} CONNECT response headers exceed {MAX_CONNECT_RESPONSE_BYTES} bytes",
                endpoint.display_addr()
            )));
        }
        let n = stream.read(&mut buf[used..]).await?;
        if n == 0 {
            return Err(IoError::new(
                ErrorKind::UnexpectedEof,
                format!(
                    "upstream proxy {} closed the connection during CONNECT",
                    endpoint.display_addr()
                ),
            ));
        }
        used += n;
        if buf[..used].windows(4).any(|win| win == b"\r\n\r\n") {
            break;
        }
    }

    let response = String::from_utf8_lossy(&buf[..used]);
    let status_line = response.lines().next().unwrap_or_default();
    let status_code = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok());
    match status_code {
        Some(200) => {
            debug!(
                proxy = %endpoint.display_addr(),
                target = %target,
                "upstream proxy CONNECT tunnel established"
            );
            Ok(stream)
        }
        Some(code) => Err(IoError::other(format!(
            "upstream proxy {} refused CONNECT to {target}: HTTP {code}",
            endpoint.display_addr()
        ))),
        None => Err(IoError::new(
            ErrorKind::InvalidData,
            format!(
                "upstream proxy {} sent a malformed CONNECT response",
                endpoint.display_addr()
            ),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openshell_core::sandbox_env::{
        UPSTREAM_HTTP_PROXY as HTTP_PROXY, UPSTREAM_HTTPS_PROXY as HTTPS_PROXY,
        UPSTREAM_NO_PROXY as NO_PROXY,
    };

    fn config_from(pairs: &[(&str, &str)]) -> Option<UpstreamProxyConfig> {
        UpstreamProxyConfig::from_lookup(|name| {
            pairs
                .iter()
                .find(|(k, _)| *k == name)
                .map(|(_, v)| (*v).to_string())
        })
    }

    #[test]
    fn no_env_yields_none() {
        assert!(config_from(&[]).is_none());
    }

    #[test]
    fn conventional_proxy_vars_are_ignored() {
        // The sandbox creator controls these names; they must not steer the
        // supervisor's operator-owned egress boundary.
        assert!(
            config_from(&[
                ("HTTPS_PROXY", "http://attacker:9999"),
                ("HTTP_PROXY", "http://attacker:9999"),
                ("ALL_PROXY", "http://attacker:9999"),
                ("https_proxy", "http://attacker:9999"),
            ])
            .is_none()
        );
    }

    #[test]
    fn empty_values_yield_none() {
        assert!(config_from(&[(HTTPS_PROXY, "  "), (HTTP_PROXY, "")]).is_none());
    }

    #[test]
    fn https_proxy_parsed_with_port() {
        let cfg = config_from(&[(HTTPS_PROXY, "http://proxy.corp.com:8080")]).unwrap();
        let ep = cfg
            .proxy_for(UpstreamScheme::Https, "api.stripe.com")
            .unwrap();
        assert_eq!(ep.display_addr(), "proxy.corp.com:8080");
        assert!(ep.proxy_authorization.is_none());
        assert!(
            cfg.proxy_for(UpstreamScheme::Http, "api.stripe.com")
                .is_none()
        );
    }

    #[test]
    fn scheme_defaults_to_http_and_port_defaults_to_80() {
        let cfg = config_from(&[(HTTP_PROXY, "proxy.corp.com")]).unwrap();
        let ep = cfg.proxy_for(UpstreamScheme::Http, "example.com").unwrap();
        assert_eq!(ep.display_addr(), "proxy.corp.com:80");
    }

    #[test]
    fn tls_and_socks_proxies_rejected() {
        assert!(config_from(&[(HTTPS_PROXY, "https://proxy:443")]).is_none());
        assert!(config_from(&[(HTTPS_PROXY, "socks5://proxy:1080")]).is_none());
    }

    #[test]
    fn url_userinfo_is_ignored_not_used_as_credentials() {
        // Inline credentials in the URL must never become the proxy auth;
        // credentials come only from the auth file.
        let cfg = config_from(&[(HTTPS_PROXY, "http://user:secret@proxy:8080")]).unwrap();
        let ep = cfg.proxy_for(UpstreamScheme::Https, "example.com").unwrap();
        assert_eq!(ep.display_addr(), "proxy:8080");
        assert!(
            ep.proxy_authorization.is_none(),
            "URL userinfo must not be used as proxy credentials"
        );
    }

    #[test]
    fn basic_auth_header_encodes_and_rejects_control_chars() {
        assert_eq!(
            basic_auth_header("user:p@ss").as_deref(),
            Some(
                format!(
                    "Basic {}",
                    base64::engine::general_purpose::STANDARD.encode("user:p@ss")
                )
                .as_str()
            )
        );
        assert!(basic_auth_header("  ").is_none());
        assert!(basic_auth_header("user:pa\r\nss").is_none());
        assert!(basic_auth_header("user:pa\nInjected: header").is_none());
    }

    #[test]
    fn apply_proxy_auth_sets_header_on_all_endpoints() {
        let mut cfg = config_from(&[
            (HTTPS_PROXY, "http://proxy:8080"),
            (HTTP_PROXY, "http://proxy:3128"),
        ])
        .unwrap();
        cfg.apply_proxy_auth(basic_auth_header("user:secret"));
        for scheme in [UpstreamScheme::Https, UpstreamScheme::Http] {
            let ep = cfg.proxy_for(scheme, "example.com").unwrap();
            let auth = ep.proxy_authorization.as_deref().unwrap();
            let expected = base64::engine::general_purpose::STANDARD.encode("user:secret");
            assert_eq!(auth, format!("Basic {expected}"));
        }
    }

    #[test]
    fn debug_output_hides_credentials() {
        let mut cfg = config_from(&[(HTTPS_PROXY, "http://proxy:8080")]).unwrap();
        cfg.apply_proxy_auth(basic_auth_header("user:secret"));
        let debug = format!("{cfg:?}");
        assert!(!debug.contains("secret"));
        assert!(!cfg.summary().contains("secret"));
    }

    #[test]
    fn ipv6_proxy_address_parses() {
        let cfg = config_from(&[(HTTPS_PROXY, "http://[fd00::1]:8080")]).unwrap();
        let ep = cfg.proxy_for(UpstreamScheme::Https, "example.com").unwrap();
        assert_eq!(ep.display_addr(), "fd00::1:8080");
    }

    // -- NO_PROXY matching --

    fn no_proxy_cfg(no_proxy: &str) -> UpstreamProxyConfig {
        config_from(&[(HTTPS_PROXY, "http://proxy:8080"), (NO_PROXY, no_proxy)]).unwrap()
    }

    fn bypasses(cfg: &UpstreamProxyConfig, host: &str) -> bool {
        cfg.proxy_for(UpstreamScheme::Https, host).is_none()
    }

    #[test]
    fn no_proxy_domain_suffix_matches_host_and_subdomains() {
        let cfg = no_proxy_cfg("corp.com,other.example");
        assert!(bypasses(&cfg, "corp.com"));
        assert!(bypasses(&cfg, "api.corp.com"));
        assert!(!bypasses(&cfg, "notcorp.com"));
        assert!(!bypasses(&cfg, "corp.com.evil.io"));
    }

    #[test]
    fn no_proxy_leading_dot_and_wildcard_prefix_are_equivalent() {
        for entry in [".svc.cluster.local", "*.svc.cluster.local"] {
            let cfg = no_proxy_cfg(entry);
            assert!(
                bypasses(&cfg, "kubernetes.default.svc.cluster.local"),
                "{entry}"
            );
            assert!(!bypasses(&cfg, "example.com"), "{entry}");
        }
    }

    #[test]
    fn no_proxy_cidr_matches_ip_literals() {
        let cfg = no_proxy_cfg("10.96.0.0/12");
        assert!(bypasses(&cfg, "10.96.0.1"));
        assert!(bypasses(&cfg, "10.100.20.30"));
        assert!(!bypasses(&cfg, "10.200.0.9"));
        assert!(!bypasses(&cfg, "93.184.216.34"));
    }

    #[test]
    fn no_proxy_exact_ip_matches() {
        let cfg = no_proxy_cfg("192.168.1.5");
        assert!(bypasses(&cfg, "192.168.1.5"));
        assert!(!bypasses(&cfg, "192.168.1.6"));
    }

    #[test]
    fn no_proxy_wildcard_bypasses_everything() {
        let cfg = no_proxy_cfg("*");
        assert!(bypasses(&cfg, "example.com"));
    }

    #[test]
    fn no_proxy_ignores_port_qualifiers() {
        let cfg = no_proxy_cfg("internal.corp:8443");
        assert!(bypasses(&cfg, "internal.corp"));
        assert!(bypasses(&cfg, "svc.internal.corp"));
    }

    #[test]
    fn loopback_and_localhost_always_bypass() {
        let cfg = no_proxy_cfg("");
        assert!(bypasses(&cfg, "localhost"));
        assert!(bypasses(&cfg, "127.0.0.1"));
        assert!(bypasses(&cfg, "::1"));
        assert!(!bypasses(&cfg, "example.com"));
    }

    // -- CONNECT handshake --

    async fn fake_proxy(
        response: &'static str,
    ) -> (std::net::SocketAddr, tokio::task::JoinHandle<String>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 4096];
            let mut used = 0;
            loop {
                let n = socket.read(&mut buf[used..]).await.unwrap();
                used += n;
                if n == 0 || buf[..used].windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            socket.write_all(response.as_bytes()).await.unwrap();
            String::from_utf8_lossy(&buf[..used]).into_owned()
        });
        (addr, handle)
    }

    fn endpoint_for(addr: std::net::SocketAddr, auth: Option<&str>) -> ProxyEndpoint {
        ProxyEndpoint {
            host: addr.ip().to_string(),
            port: addr.port(),
            proxy_authorization: auth.map(str::to_string),
        }
    }

    #[tokio::test]
    async fn connect_via_success_sends_connect_and_auth() {
        let (addr, handle) = fake_proxy("HTTP/1.1 200 Connection established\r\n\r\n").await;
        let endpoint = endpoint_for(addr, Some("Basic dXNlcjpwYXNz"));
        let stream = connect_via(&endpoint, "api.example.com", 443)
            .await
            .unwrap();
        drop(stream);
        let request = handle.await.unwrap();
        assert!(request.starts_with("CONNECT api.example.com:443 HTTP/1.1\r\n"));
        assert!(request.contains("Host: api.example.com:443\r\n"));
        assert!(request.contains("Proxy-Authorization: Basic dXNlcjpwYXNz\r\n"));
    }

    #[tokio::test]
    async fn connect_via_rejects_non_200() {
        let (addr, _handle) =
            fake_proxy("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n").await;
        let endpoint = endpoint_for(addr, None);
        let err = connect_via(&endpoint, "api.example.com", 443)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("407"), "{err}");
    }

    #[tokio::test]
    async fn connect_via_rejects_malformed_response() {
        let (addr, _handle) = fake_proxy("garbage without status\r\n\r\n").await;
        let endpoint = endpoint_for(addr, None);
        let err = connect_via(&endpoint, "api.example.com", 443)
            .await
            .unwrap_err();
        assert_eq!(err.kind(), ErrorKind::InvalidData);
    }

    #[tokio::test]
    async fn connect_via_ipv6_target_is_bracketed() {
        let (addr, handle) = fake_proxy("HTTP/1.1 200 OK\r\n\r\n").await;
        let endpoint = endpoint_for(addr, None);
        let _ = connect_via(&endpoint, "2001:db8::1", 443).await.unwrap();
        let request = handle.await.unwrap();
        assert!(request.starts_with("CONNECT [2001:db8::1]:443 HTTP/1.1\r\n"));
    }
}
