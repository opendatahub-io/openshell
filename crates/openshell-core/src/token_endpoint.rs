// SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//! Token endpoint validation for provider profiles and workspace secrets.
//!
//! A workspace secret names the only token endpoints its value may be sent to.
//! Creation and every mint compare endpoints in this normalized form, so the
//! two checks cannot disagree about what a URL means.

/// Parse a credential or OIDC endpoint without changing its effective path.
/// Literal and percent-encoded carets can identify different HTTP resources.
///
/// # Errors
///
/// Rejects invalid URLs and paths whose destination changes under caret encoding.
/// Callers enforce the scheme and authority rules for their particular credential flow.
pub fn parse_auth_url(raw: &str) -> Result<url::Url, &'static str> {
    let parse = |s: &str| url::Url::parse(s).map_err(|_| "must be an absolute URL");
    let url = parse(raw)?;
    // Ask the URL parser which carets survive in the path. A caret in the query
    // or password, or in a removed dot segment, does not change the destination path.
    if raw.contains('^') && parse(&raw.replace('^', "_"))?.path() != url.path() {
        return Err(
            "contains a literal caret (^) in its path. Confirm the intended destination and reconfigure the URL",
        );
    }
    Ok(url)
}

/// Normalize a token endpoint for exact comparison.
///
/// Accepts absolute `https` URLs, or `http` URLs for loopback hosts (local
/// tests). Rejects user information, queries, and fragments. The result has a
/// lowercase scheme and host, no default port, and a non-empty path.
///
/// # Errors
///
/// Returns a short description of why the URL is not an acceptable endpoint.
pub fn normalize_token_endpoint(raw: &str) -> Result<String, &'static str> {
    parse_token_endpoint(raw.trim()).map(Into::into)
}

/// Resolve a GitHub App profile's token endpoint while preserving GHES path prefixes.
///
/// # Errors
///
/// Rejects invalid installation path templates and disallowed token endpoints.
pub fn github_app_installation_url(template: &str, id: u64) -> Result<url::Url, &'static str> {
    parse_token_endpoint(expand_github_app_template(template, id)?.trim())
}

/// Check a GitHub App profile template's structure while loading the catalog.
/// Existing profiles with literal carets must stay readable so owners can repair them.
///
/// # Errors
///
/// Rejects invalid installation templates, transports, and authorities.
pub fn validate_github_app_template(template: &str) -> Result<(), &'static str> {
    let endpoint = expand_github_app_template(template, 1)?;
    let url = url::Url::parse(endpoint.trim()).map_err(|_| "must be an absolute URL")?;
    validate_token_endpoint(&url)
}

fn expand_github_app_template(template: &str, id: u64) -> Result<String, &'static str> {
    const PLACEHOLDER: &str = "{installation_id}";
    if !template.ends_with("/app/installations/{installation_id}/access_tokens")
        || template.matches(PLACEHOLDER).count() != 1
    {
        return Err(
            "must end with /app/installations/{installation_id}/access_tokens and contain one installation ID placeholder",
        );
    }
    Ok(template.replace(PLACEHOLDER, &id.to_string()))
}

/// Parse the request destination when binding a workspace secret to a provider.
///
/// # Errors
///
/// Rejects endpoints with ambiguous paths or components disallowed for workspace secrets.
pub fn parse_token_endpoint(raw: &str) -> Result<url::Url, &'static str> {
    let url = parse_auth_url(raw)?;
    validate_token_endpoint(&url)?;
    Ok(url)
}

fn validate_token_endpoint(url: &url::Url) -> Result<(), &'static str> {
    let Some(host) = url.host_str().filter(|host| !host.is_empty()) else {
        return Err("must include a host");
    };
    match url.scheme() {
        "https" => {}
        "http" if is_loopback_host(host) => {}
        _ => return Err("must use https, or http for a loopback host"),
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("must not include user information");
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err("must not include a query or fragment");
    }
    Ok(())
}

/// Whether a token endpoint's URL host may use plain HTTP.
#[must_use]
pub fn is_loopback_host(host: &str) -> bool {
    matches!(host, "localhost" | "127.0.0.1" | "::1" | "[::1]")
}

#[cfg(test)]
mod tests {
    use super::normalize_token_endpoint;

    #[test]
    fn normalizes_case_default_port_and_empty_path() {
        assert_eq!(
            normalize_token_endpoint("HTTPS://Login.Example.COM:443").unwrap(),
            "https://login.example.com/"
        );
        assert_eq!(
            normalize_token_endpoint(" https://login.example.com:8443/oauth/token ").unwrap(),
            "https://login.example.com:8443/oauth/token"
        );
    }

    #[test]
    fn checks_the_effective_path_before_losing_the_caret_spelling() {
        for raw in [
            "https://example.com/a^b",
            "https://example.com/a^%5E",
            r"https:\example.com\a^b",
        ] {
            assert!(
                super::parse_auth_url(raw)
                    .unwrap_err()
                    .contains("literal caret")
            );
        }
        for raw in [
            "https://example.com/%5E/%5e/%255E",
            "https://example.com/a^b/../token",
            "https://user:p^w@example.com/%5E?x=^#^",
        ] {
            assert_eq!(
                super::parse_auth_url(raw),
                Ok(url::Url::parse(raw).unwrap())
            );
        }
    }

    #[test]
    fn allows_http_only_for_loopback() {
        assert!(normalize_token_endpoint("http://127.0.0.1:9000/token").is_ok());
        assert!(normalize_token_endpoint("http://localhost/token").is_ok());
        assert!(normalize_token_endpoint("http://[::1]:9000/token").is_ok());
        assert!(normalize_token_endpoint("http://login.example.com/token").is_err());
    }

    #[test]
    fn loopback_hosts_match_url_host_strings() {
        for raw in ["http://localhost/", "http://127.0.0.1/", "http://[::1]/"] {
            let host = url::Url::parse(raw)
                .unwrap()
                .host_str()
                .unwrap()
                .to_string();
            assert!(super::is_loopback_host(&host), "{raw} -> {host}");
        }
        assert!(!super::is_loopback_host("login.example.com"));
    }

    #[test]
    fn rejects_ambiguous_or_credential_bearing_urls() {
        for raw in [
            "",
            "/oauth/token",
            "ftp://login.example.com/token",
            "https://user:pass@login.example.com/token",
            "https://login.example.com/token?tenant=a",
            "https://login.example.com/token#frag",
        ] {
            assert!(normalize_token_endpoint(raw).is_err(), "{raw}");
        }
    }
}
