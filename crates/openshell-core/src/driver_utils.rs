// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Utility helpers shared across compute-driver crates.

use std::path::PathBuf;

use crate::proto::compute::v1::{DriverSandbox, GetCapabilitiesResponse};

// ---------------------------------------------------------------------------
// Sandbox container/pod label keys (openshell.ai/ namespace)
// ---------------------------------------------------------------------------

/// Container/pod label that identifies this resource as managed by `OpenShell`.
/// Value should be `"openshell"`.
pub const LABEL_MANAGED_BY: &str = "openshell.ai/managed-by";

/// Expected value for [`LABEL_MANAGED_BY`].
pub const LABEL_MANAGED_BY_VALUE: &str = "openshell";

/// Container/pod label carrying the sandbox ID.
pub const LABEL_SANDBOX_ID: &str = "openshell.ai/sandbox-id";

/// Container/pod label carrying the sandbox name.
pub const LABEL_SANDBOX_NAME: &str = "openshell.ai/sandbox-name";

/// Container/pod label carrying the sandbox namespace.
pub const LABEL_SANDBOX_NAMESPACE: &str = "openshell.ai/sandbox-namespace";

/// Container/pod label carrying the sandbox workspace.
pub const LABEL_SANDBOX_WORKSPACE: &str = "openshell.ai/sandbox-workspace";

// ---------------------------------------------------------------------------

/// Path to the sandbox supervisor binary inside the container image.
///
/// All compute drivers must launch this binary as the container entrypoint to
/// start the sandboxed environment.  The value must be kept in sync with the
/// path used when building the `openshell-sandbox` image layer.
pub const SUPERVISOR_IMAGE_BINARY_PATH: &str = "/openshell-sandbox";

/// Directory inside sandbox containers where the supervisor binary is mounted.
///
/// Compute drivers that side-load the supervisor into a shared volume mount
/// the binary here so the sandbox container can execute it from a fixed path.
pub const SUPERVISOR_CONTAINER_DIR: &str = "/opt/openshell/bin";

/// Full path to the supervisor binary inside sandbox containers.
///
/// Equals `SUPERVISOR_CONTAINER_DIR + "/openshell-sandbox"`. Use this when
/// the full executable path is needed (Docker entrypoint, Podman entrypoint,
/// VM rootfs injection). Use `SUPERVISOR_CONTAINER_DIR` when only the
/// directory mount-point is needed (Kubernetes emptyDir volume mount).
pub const SUPERVISOR_CONTAINER_BINARY: &str = "/opt/openshell/bin/openshell-sandbox";

// ---------------------------------------------------------------------------
// In-container mount paths for guest TLS materials and the sandbox token.
//
// All container-based drivers (Docker, Podman, Kubernetes) mount the gateway's
// mTLS client credentials at these fixed paths inside every sandbox container.
// The supervisor reads these paths on startup to establish its gRPC-over-mTLS
// connection back to the gateway. The paths must remain stable across driver
// versions since the supervisor binary is built and packaged separately.
// ---------------------------------------------------------------------------

/// Container-side mount path for the guest mTLS CA certificate.
pub const TLS_CA_MOUNT_PATH: &str = "/etc/openshell/tls/client/ca.crt";

/// Container-side mount path for the guest mTLS client certificate.
pub const TLS_CERT_MOUNT_PATH: &str = "/etc/openshell/tls/client/tls.crt";

/// Container-side mount path for the guest mTLS client private key.
pub const TLS_KEY_MOUNT_PATH: &str = "/etc/openshell/tls/client/tls.key";

/// Container-side mount path for the per-sandbox JWT token.
pub const SANDBOX_TOKEN_MOUNT_PATH: &str = "/etc/openshell/auth/sandbox.jwt";

/// Container-side mount path for the corporate upstream-proxy credentials.
///
/// The file holds the `user:pass` userinfo used to build the
/// `Proxy-Authorization` header. It is delivered through a root-only secret
/// mount so the credential never appears in container environment/metadata.
pub const UPSTREAM_PROXY_AUTH_MOUNT_PATH: &str = "/etc/openshell/auth/upstream-proxy";

/// A validated corporate upstream-proxy address.
///
/// Produced by [`parse_upstream_proxy_url`], which is the single source of
/// truth for what counts as a valid upstream proxy URL. Compute drivers use
/// it to reject bad operator config at sandbox-create time, and the
/// in-container supervisor applies the same rules to the reserved
/// `OPENSHELL_UPSTREAM_*` variables so a value one side accepts is never
/// rejected (or silently ignored) by the other.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpstreamProxyAddr {
    /// Proxy hostname, IPv4, or IPv6 address (IPv6 without brackets).
    pub host: String,
    /// Proxy TCP port (defaults to 80 when the URL has none).
    pub port: u16,
}

/// Why an upstream proxy URL was rejected by [`parse_upstream_proxy_url`].
///
/// Kept as a typed error so each consumer (driver config validation,
/// supervisor startup) can phrase the message for its own surface while
/// enforcing identical semantics.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UpstreamProxyUrlError {
    /// The value is empty or whitespace-only.
    #[error("proxy URL is empty")]
    Empty,
    /// The value does not parse as a URL.
    #[error("not a valid proxy URL: {0}")]
    Invalid(url::ParseError),
    /// The URL uses a scheme other than `http` (TLS and SOCKS proxies are
    /// not supported by the sandbox supervisor).
    #[error(
        "unsupported proxy scheme '{0}': only http:// forward proxies are \
         supported by the sandbox supervisor"
    )]
    UnsupportedScheme(String),
    /// The URL embeds `user:pass@` credentials, which would leak into config
    /// and container metadata. Credentials must come from the proxy auth file.
    #[error("proxy URL must not embed credentials; supply them via the proxy auth file")]
    InlineCredentials,
    /// The URL has no host component.
    #[error("proxy URL is missing a proxy host")]
    MissingHost,
}

/// Parse and validate a corporate upstream-proxy URL.
///
/// A bare `host:port` (no `://`) is normalized to `http://host:port`. Only
/// `http://` proxies are accepted, inline userinfo is rejected, and the port
/// defaults to 80.
///
/// # Errors
///
/// Returns an [`UpstreamProxyUrlError`] describing the first rule the value
/// violates.
pub fn parse_upstream_proxy_url(raw: &str) -> Result<UpstreamProxyAddr, UpstreamProxyUrlError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(UpstreamProxyUrlError::Empty);
    }
    let parsed = if trimmed.contains("://") {
        url::Url::parse(trimmed)
    } else {
        url::Url::parse(&format!("http://{trimmed}"))
    }
    .map_err(UpstreamProxyUrlError::Invalid)?;

    if !parsed.scheme().eq_ignore_ascii_case("http") {
        return Err(UpstreamProxyUrlError::UnsupportedScheme(
            parsed.scheme().to_string(),
        ));
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(UpstreamProxyUrlError::InlineCredentials);
    }
    let host = match parsed.host() {
        // `Host::Ipv6` renders without brackets, which is what socket
        // connect APIs expect.
        Some(url::Host::Ipv6(ip)) => ip.to_string(),
        Some(host) => host.to_string(),
        None => return Err(UpstreamProxyUrlError::MissingHost),
    };
    if host.is_empty() {
        return Err(UpstreamProxyUrlError::MissingHost);
    }
    Ok(UpstreamProxyAddr {
        host,
        port: parsed.port().unwrap_or(80),
    })
}

/// Return the XDG state path for a driver's sandbox JWT token file.
///
/// The resulting path is `$XDG_STATE_HOME/openshell/<driver_subdir>[/<namespace>]/<sandbox_id>/sandbox.jwt`.
///
/// `driver_subdir` is driver-specific, e.g. `"docker-sandbox-tokens"` or
/// `"podman-sandbox-tokens"`.  When `namespace` is `Some`, it is appended as
/// an additional path component (with `/` and `\` replaced by `-`).
///
/// # Errors
/// Returns an error if the XDG state directory cannot be resolved.
pub fn sandbox_token_path(
    driver_subdir: &str,
    namespace: Option<&str>,
    sandbox_id: &str,
) -> miette::Result<PathBuf> {
    let mut path = crate::paths::xdg_state_dir()?
        .join("openshell")
        .join(driver_subdir);
    if let Some(ns) = namespace {
        path = path.join(ns.replace(['/', '\\'], "-"));
    }
    Ok(path.join(sandbox_id).join("sandbox.jwt"))
}

/// Build a [`GetCapabilitiesResponse`] from the common driver capability fields.
///
/// Every compute driver constructs this response with the same fields. Shared
/// here to avoid repeating the struct literal in each driver crate.
pub fn build_capabilities_response(
    driver_name: &str,
    driver_version: impl Into<String>,
    default_image: impl Into<String>,
) -> GetCapabilitiesResponse {
    GetCapabilitiesResponse {
        driver_name: driver_name.to_string(),
        driver_version: driver_version.into(),
        default_image: default_image.into(),
    }
}

/// Return the effective log level for a sandbox.
///
/// Uses the level from the sandbox spec when non-empty, falling back to
/// `default_level` otherwise.
pub fn sandbox_log_level(sandbox: &DriverSandbox, default_level: &str) -> String {
    sandbox
        .spec
        .as_ref()
        .map(|spec| spec.log_level.as_str())
        .filter(|level| !level.is_empty())
        .unwrap_or(default_level)
        .to_string()
}

// ---------------------------------------------------------------------------
// Supervisor image helpers (shared by Docker and Podman drivers)
// ---------------------------------------------------------------------------

/// Return the tag portion of a supervisor image reference, or `None` if the
/// reference uses a digest (`@sha256:...`).
///
/// Examples:
/// - `"ghcr.io/org/image:1.2.3"` → `Some("1.2.3")`
/// - `"ghcr.io/org/image:latest"` → `Some("latest")`
/// - `"ghcr.io/org/image"` → `Some("latest")`  (implied tag)
/// - `"ghcr.io/org/image@sha256:abc"` → `None`  (pinned by digest)
/// - `"ghcr.io/org/image:"` → `None`  (empty tag)
pub fn supervisor_image_tag(image: &str) -> Option<&str> {
    if image.contains('@') {
        return None;
    }

    let image_name = image.rsplit('/').next().unwrap_or(image);
    image_name
        .rsplit_once(':')
        .map_or(Some("latest"), |(_, tag)| {
            if tag.is_empty() { None } else { Some(tag) }
        })
}

/// Return `true` if the supervisor image should be refreshed before each use.
///
/// Mutable tags (`dev`, `latest`) are always re-pulled so that the running
/// container tracks the latest pushed version.  Digest-pinned references and
/// all other versioned tags are treated as immutable and pulled at most once.
pub fn supervisor_image_should_refresh(image: &str) -> bool {
    matches!(supervisor_image_tag(image), Some("dev" | "latest"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upstream_proxy_url_accepts_http_with_port() {
        let addr = parse_upstream_proxy_url("http://proxy.corp.com:8080").unwrap();
        assert_eq!(addr.host, "proxy.corp.com");
        assert_eq!(addr.port, 8080);
    }

    #[test]
    fn upstream_proxy_url_defaults_scheme_and_port() {
        let addr = parse_upstream_proxy_url("proxy.corp.com").unwrap();
        assert_eq!(addr.host, "proxy.corp.com");
        assert_eq!(addr.port, 80);
        let addr = parse_upstream_proxy_url("proxy.corp.com:3128").unwrap();
        assert_eq!(addr.port, 3128);
    }

    #[test]
    fn upstream_proxy_url_ipv6_host_is_bracket_free() {
        let addr = parse_upstream_proxy_url("http://[fd00::1]:8080").unwrap();
        assert_eq!(addr.host, "fd00::1");
        assert_eq!(addr.port, 8080);
    }

    #[test]
    fn upstream_proxy_url_rejects_tls_and_socks_schemes() {
        for url in ["https://proxy:443", "socks5://proxy:1080"] {
            assert!(matches!(
                parse_upstream_proxy_url(url),
                Err(UpstreamProxyUrlError::UnsupportedScheme(_))
            ));
        }
    }

    #[test]
    fn upstream_proxy_url_rejects_inline_credentials() {
        for url in ["http://user:pass@proxy:8080", "http://user@proxy:8080"] {
            assert_eq!(
                parse_upstream_proxy_url(url),
                Err(UpstreamProxyUrlError::InlineCredentials)
            );
        }
    }

    #[test]
    fn upstream_proxy_url_rejects_empty_and_invalid() {
        assert_eq!(
            parse_upstream_proxy_url("  "),
            Err(UpstreamProxyUrlError::Empty)
        );
        assert!(matches!(
            parse_upstream_proxy_url("http://proxy:notaport"),
            Err(UpstreamProxyUrlError::Invalid(_))
        ));
        assert!(parse_upstream_proxy_url("http://").is_err());
    }
}
