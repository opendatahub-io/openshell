// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Upstream corporate proxy chaining for the sandbox egress proxy.
//!
//! In proxy-required enterprise networks (issue #1792) the supervisor cannot
//! dial policy-approved destinations directly: all outbound traffic must go
//! through a corporate forward proxy. This module reads the operator-owned
//! reserved `OPENSHELL_UPSTREAM_HTTPS_PROXY` / `OPENSHELL_UPSTREAM_NO_PROXY`
//! variables from the supervisor's **own** environment and chains approved
//! TLS tunnels through the corporate proxy with HTTP CONNECT.
//!
//! Only TLS (CONNECT) egress is chained: plain-HTTP requests always dial the
//! destination directly. Forwarding plain HTTP through a corporate proxy
//! requires absolute-form request forwarding rather than CONNECT tunneling
//! and is out of scope for this feature.
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
//! - Only `http://` proxy URLs are supported. Configuration is fail-closed:
//!   any present-but-invalid reserved value — a present-but-empty variable,
//!   an unsupported (`https://`, SOCKS) or malformed proxy URL, an unreadable
//!   auth file, or a malformed credential — is a fatal startup error rather
//!   than being silently ignored, so a typo can never quietly downgrade the
//!   operator's egress boundary to direct dialing or unauthenticated proxy
//!   access. Validation semantics are shared with the compute driver via
//!   [`openshell_core::driver_utils::parse_upstream_proxy_url`] and
//!   [`openshell_core::driver_utils::parse_upstream_proxy_credential`].
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
use tracing::debug;

/// Upper bound on the corporate proxy's CONNECT response header block.
const MAX_CONNECT_RESPONSE_BYTES: usize = 8 * 1024;

/// End-to-end budget for dialing the corporate proxy and completing the
/// CONNECT handshake.
const CONNECT_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);

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
    https: ProxyEndpoint,
    no_proxy: NoProxy,
}

impl UpstreamProxyConfig {
    /// Read the operator-owned corporate proxy configuration from the
    /// supervisor's reserved environment variables
    /// ([`UPSTREAM_HTTPS_PROXY`](openshell_core::sandbox_env::UPSTREAM_HTTPS_PROXY),
    /// [`UPSTREAM_NO_PROXY`](openshell_core::sandbox_env::UPSTREAM_NO_PROXY),
    /// [`UPSTREAM_PROXY_AUTH_FILE`](openshell_core::sandbox_env::UPSTREAM_PROXY_AUTH_FILE)).
    /// Returns `Ok(None)` when no proxy is configured (unset variables).
    ///
    /// The conventional `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` / `NO_PROXY`
    /// variables are intentionally ignored here: they are set by the sandbox
    /// creator (and rewritten to point workload children at the local policy
    /// proxy), so honoring them would let a sandbox choose an arbitrary
    /// upstream proxy or disable proxying entirely. The compute driver writes
    /// the reserved names in its required-variable tier, where sandbox and
    /// template environment cannot override them.
    ///
    /// # Errors
    ///
    /// These reserved variables are an operator-owned security boundary, so
    /// any present-but-invalid value is fatal instead of being treated as
    /// unset: a present-but-empty (or whitespace-only) reserved variable, an
    /// invalid or unsupported proxy URL, an auth file that is set but
    /// unreadable or holds a malformed credential, or an auth file or
    /// `NO_PROXY` list with no proxy configured. Failing closed here
    /// prevents a misconfiguration
    /// from silently degrading to direct dialing or unauthenticated proxy
    /// access. Only fully unset variables mean "no proxy".
    pub fn from_env() -> Result<Option<Self>, String> {
        Self::from_lookup(|name| std::env::var(name).ok())
    }

    fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Result<Option<Self>, String> {
        use openshell_core::sandbox_env::{
            UPSTREAM_HTTPS_PROXY, UPSTREAM_NO_PROXY, UPSTREAM_PROXY_AUTH_FILE,
        };
        // Only a fully unset reserved variable means "not configured". A
        // present-but-empty value is a misconfiguration (the compute driver
        // never writes one), so it is fatal rather than silently downgrading
        // the boundary to direct dialing or unauthenticated proxy access.
        let var = |name: &str| -> Result<Option<String>, String> {
            match lookup(name) {
                None => Ok(None),
                Some(value) if value.trim().is_empty() => Err(format!(
                    "{name} is set but empty; unset it to disable the upstream proxy"
                )),
                Some(value) => Ok(Some(value)),
            }
        };
        let https = var(UPSTREAM_HTTPS_PROXY)?
            .map(|url| parse_proxy_url(&url, UPSTREAM_HTTPS_PROXY))
            .transpose()?;
        let auth_file = var(UPSTREAM_PROXY_AUTH_FILE)?;
        let no_proxy_list = var(UPSTREAM_NO_PROXY)?;
        let Some(mut https) = https else {
            // Auxiliary proxy settings without a proxy mean the operator
            // believed a proxy boundary was in effect; refuse rather than
            // silently running with direct egress.
            for (name, value) in [
                (UPSTREAM_PROXY_AUTH_FILE, &auth_file),
                (UPSTREAM_NO_PROXY, &no_proxy_list),
            ] {
                if value.is_some() {
                    return Err(format!("{name} is set but no upstream proxy is configured"));
                }
            }
            return Ok(None);
        };

        // Load proxy credentials from the reserved auth file, if configured.
        // The file is delivered through a root-only secret mount so the
        // credentials never appear in the environment or container metadata.
        if let Some(path) = auth_file {
            let credential = std::fs::read_to_string(&path).map_err(|err| {
                format!("failed to read upstream proxy auth file '{path}': {err}")
            })?;
            let header = basic_auth_header(&credential).map_err(|err| {
                format!("invalid credential in upstream proxy auth file '{path}': {err}")
            })?;
            https.proxy_authorization = Some(header);
        }

        Ok(Some(Self {
            https,
            no_proxy: NoProxy::parse(&no_proxy_list.unwrap_or_default()),
        }))
    }

    /// The corporate proxy to use for a TLS tunnel to `host`, or `None` when
    /// the destination must be dialed directly.
    #[must_use]
    pub fn proxy_for(&self, host: &str) -> Option<&ProxyEndpoint> {
        if self.no_proxy.matches(host) {
            return None;
        }
        Some(&self.https)
    }

    /// Credential-free summary for startup logging.
    #[must_use]
    pub fn summary(&self) -> String {
        format!(
            "https_proxy={} no_proxy_entries={}",
            self.https.display_addr(),
            self.no_proxy.entries.len()
        )
    }
}

/// Parse an `http://host[:port]` proxy URL with the same validation rules the
/// compute driver applies at sandbox-create time
/// ([`parse_upstream_proxy_url`](openshell_core::driver_utils::parse_upstream_proxy_url)).
///
/// Credentials are never taken from the URL: they are delivered out of band
/// through [`UPSTREAM_PROXY_AUTH_FILE`](openshell_core::sandbox_env::UPSTREAM_PROXY_AUTH_FILE)
/// so they never appear in config or container metadata.
///
/// # Errors
///
/// Rejects unsupported schemes (TLS or SOCKS proxies), inline `user:pass@`
/// credentials, and malformed addresses. The error names `var_name` so the
/// operator can locate the offending setting.
fn parse_proxy_url(raw: &str, var_name: &str) -> Result<ProxyEndpoint, String> {
    let addr = openshell_core::driver_utils::parse_upstream_proxy_url(raw)
        .map_err(|err| format!("{var_name} is invalid: {err}"))?;
    Ok(ProxyEndpoint {
        host: addr.host,
        port: addr.port,
        proxy_authorization: None,
    })
}

/// Build a `Proxy-Authorization: Basic <base64>` header value from a raw
/// `user:pass` credential.
///
/// The credential is used verbatim after trimming: it is delivered through a
/// trusted operator file, not a URL, so there is no percent-encoding to
/// decode. Validation is shared with the compute driver through
/// [`parse_upstream_proxy_credential`](openshell_core::driver_utils::parse_upstream_proxy_credential),
/// so a credential the driver staged at sandbox-create time is never rejected
/// here.
///
/// # Errors
///
/// Rejects an empty credential, one containing control characters that could
/// inject additional HTTP headers, and one not in `user:pass` form. Error
/// messages never include the credential content.
fn basic_auth_header(credential: &str) -> Result<String, String> {
    let credential = openshell_core::driver_utils::parse_upstream_proxy_credential(credential)
        .map_err(|err| err.to_string())?;
    Ok(format!(
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
        UPSTREAM_HTTPS_PROXY as HTTPS_PROXY, UPSTREAM_NO_PROXY as NO_PROXY,
        UPSTREAM_PROXY_AUTH_FILE as PROXY_AUTH_FILE,
    };

    fn config_from(pairs: &[(&str, &str)]) -> Result<Option<UpstreamProxyConfig>, String> {
        UpstreamProxyConfig::from_lookup(|name| {
            pairs
                .iter()
                .find(|(k, _)| *k == name)
                .map(|(_, v)| (*v).to_string())
        })
    }

    /// Shorthand for tests exercising a configuration that must load.
    fn config_ok(pairs: &[(&str, &str)]) -> UpstreamProxyConfig {
        config_from(pairs).unwrap().unwrap()
    }

    #[test]
    fn no_env_yields_none() {
        assert!(config_from(&[]).unwrap().is_none());
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
            .unwrap()
            .is_none()
        );
    }

    #[test]
    fn present_but_empty_values_are_fatal() {
        // A reserved variable the operator did not set is absent, never
        // empty: the driver only writes configured values. A present-but
        // -blank value is therefore a misconfiguration and must not silently
        // mean "no proxy".
        for (name, value) in [
            (HTTPS_PROXY, ""),
            (HTTPS_PROXY, "  "),
            (NO_PROXY, " "),
            (PROXY_AUTH_FILE, ""),
        ] {
            let err = config_from(&[(name, value)]).unwrap_err();
            assert!(err.contains(name), "{err}");
            assert!(err.contains("empty"), "{err}");
        }
    }

    #[test]
    fn https_proxy_parsed_with_port() {
        let cfg = config_ok(&[(HTTPS_PROXY, "http://proxy.corp.com:8080")]);
        let ep = cfg.proxy_for("api.stripe.com").unwrap();
        assert_eq!(ep.display_addr(), "proxy.corp.com:8080");
        assert!(ep.proxy_authorization.is_none());
    }

    #[test]
    fn scheme_defaults_to_http_and_port_defaults_to_80() {
        let cfg = config_ok(&[(HTTPS_PROXY, "proxy.corp.com")]);
        let ep = cfg.proxy_for("example.com").unwrap();
        assert_eq!(ep.display_addr(), "proxy.corp.com:80");
    }

    // -- Fail-closed configuration validation --
    //
    // Present-but-invalid reserved values must be fatal, never silently
    // treated as unset: a typo must not downgrade the operator's egress
    // boundary to direct dialing or unauthenticated proxy access.

    #[test]
    fn tls_and_socks_proxies_are_fatal() {
        for url in ["https://proxy:443", "socks5://proxy:1080"] {
            let err = config_from(&[(HTTPS_PROXY, url)]).unwrap_err();
            assert!(err.contains(HTTPS_PROXY), "{err}");
            assert!(err.contains("scheme"), "{err}");
        }
    }

    #[test]
    fn url_userinfo_is_fatal_not_used_as_credentials() {
        // Inline credentials in the URL must never become the proxy auth;
        // credentials come only from the auth file. Matching the compute
        // driver, a URL that embeds them is rejected outright.
        let err = config_from(&[(HTTPS_PROXY, "http://user:secret@proxy:8080")]).unwrap_err();
        assert!(err.contains(HTTPS_PROXY), "{err}");
        assert!(
            !err.contains("secret"),
            "error must not leak the credential: {err}"
        );
    }

    #[test]
    fn malformed_proxy_address_is_fatal() {
        let err = config_from(&[(HTTPS_PROXY, "http://proxy:notaport")]).unwrap_err();
        assert!(err.contains(HTTPS_PROXY), "{err}");
        // A path/query/fragment addresses an endpoint, not a proxy; it is
        // rejected rather than silently discarded.
        for url in [
            "http://proxy:8080/path",
            "http://proxy:8080?x=1",
            "http://proxy:8080#frag",
        ] {
            let err = config_from(&[(HTTPS_PROXY, url)]).unwrap_err();
            assert!(err.contains(HTTPS_PROXY), "{url}: {err}");
        }
    }

    #[test]
    fn unreadable_auth_file_is_fatal() {
        let err = config_from(&[
            (HTTPS_PROXY, "http://proxy.corp.com:8080"),
            (PROXY_AUTH_FILE, "/nonexistent/upstream-proxy-auth"),
        ])
        .unwrap_err();
        assert!(err.contains("auth file"), "{err}");
    }

    #[test]
    fn malformed_auth_file_credential_is_fatal() {
        // Empty, header-injecting, and non-`user:pass` credentials are all
        // rejected by the parser shared with the compute driver.
        for credential in ["  ", "user:pa\r\nss", "userpass", ":pass"] {
            let file = tempfile::NamedTempFile::new().unwrap();
            std::fs::write(file.path(), credential).unwrap();
            let path = file.path().to_str().unwrap().to_string();
            let err = config_from(&[
                (HTTPS_PROXY, "http://proxy.corp.com:8080"),
                (PROXY_AUTH_FILE, &path),
            ])
            .unwrap_err();
            assert!(err.contains("auth file"), "{err}");
            assert!(
                !err.contains("pa\r\nss"),
                "error must not leak the credential: {err}"
            );
        }
    }

    #[test]
    fn auxiliary_settings_without_proxy_are_fatal() {
        // An auth file or NO_PROXY list only makes sense relative to a proxy
        // boundary the operator believed was in effect.
        for (name, value) in [
            (PROXY_AUTH_FILE, "/etc/openshell/auth/upstream-proxy"),
            (NO_PROXY, "*.svc.cluster.local"),
        ] {
            let err = config_from(&[(name, value)]).unwrap_err();
            assert!(err.contains(name), "{err}");
            assert!(err.contains("no upstream proxy"), "{err}");
        }
    }

    #[test]
    fn auth_file_credentials_are_applied_to_the_endpoint() {
        let file = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(file.path(), "user:secret\n").unwrap();
        let path = file.path().to_str().unwrap().to_string();
        let cfg = config_ok(&[(HTTPS_PROXY, "http://proxy:8080"), (PROXY_AUTH_FILE, &path)]);
        let expected = format!(
            "Basic {}",
            base64::engine::general_purpose::STANDARD.encode("user:secret")
        );
        let ep = cfg.proxy_for("example.com").unwrap();
        assert_eq!(ep.proxy_authorization.as_deref(), Some(expected.as_str()));
    }

    #[test]
    fn basic_auth_header_encodes_and_rejects_malformed_credentials() {
        assert_eq!(
            basic_auth_header("user:p@ss").as_deref(),
            Ok(format!(
                "Basic {}",
                base64::engine::general_purpose::STANDARD.encode("user:p@ss")
            )
            .as_str())
        );
        assert!(basic_auth_header("  ").is_err());
        assert!(basic_auth_header("user:pa\r\nss").is_err());
        assert!(basic_auth_header("user:pa\nInjected: header").is_err());
        assert!(basic_auth_header("no-separator").is_err());
    }

    #[test]
    fn debug_output_hides_credentials() {
        let mut cfg = config_ok(&[(HTTPS_PROXY, "http://proxy:8080")]);
        cfg.https.proxy_authorization = Some(basic_auth_header("user:secret").unwrap());
        let debug = format!("{cfg:?}");
        assert!(!debug.contains("secret"));
        assert!(!cfg.summary().contains("secret"));
    }

    #[test]
    fn ipv6_proxy_address_parses() {
        let cfg = config_ok(&[(HTTPS_PROXY, "http://[fd00::1]:8080")]);
        let ep = cfg.proxy_for("example.com").unwrap();
        assert_eq!(ep.display_addr(), "fd00::1:8080");
    }

    // -- NO_PROXY matching --

    fn no_proxy_cfg(no_proxy: &str) -> UpstreamProxyConfig {
        config_ok(&[(HTTPS_PROXY, "http://proxy:8080"), (NO_PROXY, no_proxy)])
    }

    fn bypasses(cfg: &UpstreamProxyConfig, host: &str) -> bool {
        cfg.proxy_for(host).is_none()
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
        // No NO_PROXY at all: loopback still bypasses unconditionally.
        let cfg = config_ok(&[(HTTPS_PROXY, "http://proxy:8080")]);
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
