#!/usr/bin/env -S uv run --script
# SPDX-FileCopyrightText: Copyright (c) 2026 OpenShell contributors
# SPDX-License-Identifier: Apache-2.0
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Read-only gateway authorization checks through the dashboard BFF and public Route."""

import argparse
import contextlib
import json
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import (
    HTTPRedirectHandler,
    HTTPSHandler,
    ProxyHandler,
    Request,
    build_opener,
)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, _req, _fp, _code, _msg, _headers, _newurl):
        # Never forward an access token or session cookie to a redirect target.
        return None


def secret_file(path):
    value = path.read_text().strip()
    if not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("Credential file must contain one nonempty header value")
    return value


def request(url, token=None, cookie=None, ca_file=None):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if cookie:
        headers["Cookie"] = cookie
    context = ssl.create_default_context()
    if ca_file:
        context.load_verify_locations(cafile=str(ca_file))
    # Loopback traffic must never pass through an environment-configured proxy.
    handlers = [NoRedirect(), HTTPSHandler(context=context)]
    if urlsplit(url).hostname == "127.0.0.1":
        handlers.append(ProxyHandler({}))
    try:
        with build_opener(*handlers).open(
            Request(url, headers=headers), timeout=30
        ) as response:
            body = response.read(1024 * 1024)
            try:
                data = json.loads(body)
            except ValueError:
                data = None
            return response.status, data
    except HTTPError as error:
        error.close()
        return error.code, None
    except (URLError, OSError):
        raise ValueError(
            "HTTP connection or TLS verification failed; check endpoint reachability and CA trust"
        ) from None


@contextlib.contextmanager
def forward(context, namespace):
    # kubectl allocates the port. Keep its diagnostics private and never write
    # tokens into argv, environment variables, or a subprocess's stdin.
    with tempfile.TemporaryFile(mode="w+") as output:
        process = subprocess.Popen(
            [
                "kubectl",
                "--context",
                context,
                "-n",
                namespace,
                "port-forward",
                "--address=127.0.0.1",
                "deployment/openshell-dashboard",
                ":8080",
            ],
            stdout=output,
            stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                output.seek(0)
                match = re.search(
                    r"Forwarding from 127\.0\.0\.1:(\d+) -> 8080", output.read()
                )
                if match:
                    yield f"http://127.0.0.1:{match[1]}"
                    return
                if process.poll() is not None:
                    break
                time.sleep(0.2)
            raise ValueError(
                "Could not port-forward the dashboard; check context, namespace, pod readiness and pods/portforward permissions"
            )
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def verify(
    base,
    public,
    admin,
    user,
    allowed,
    denied,
    admin_role,
    other=None,
    cookie=None,
    ca_file=None,
    http=request,
):
    failures = []

    def check(label, url, expected, **kwargs):
        status, data = http(url, **kwargs)
        passed = status in expected
        print(f"{'PASS' if passed else 'FAIL'}: {label} (HTTP {status})")
        if not passed:
            failures.append(label)
        return data

    def identity(label, token, is_admin):
        data = check(label, f"{base}/api/v1/auth/whoami", (200,), token=token)
        valid = (
            isinstance(data, dict)
            and bool(data.get("subject"))
            and isinstance(data.get("roles"), list)
            and (admin_role in data["roles"]) == is_admin
        )
        if not valid:
            failures.append(f"{label} identity/role")
            print(f"FAIL: {label} identity/role")
        return data.get("subject") if isinstance(data, dict) else None

    check(
        "public API rejects missing session",
        f"{public}/api/v1/workspaces",
        (401,),
        ca_file=ca_file,
    )
    check("gateway rejects missing token", f"{base}/api/v1/workspaces", (401,))
    admin_subject = identity("admin token", admin, True)
    user_subject = identity("ordinary-user token", user, False)
    if admin_subject == user_subject:
        failures.append("admin and user must be distinct identities")
    for name in (allowed, denied):
        path = f"/api/v1/workspaces/{quote(name, safe='')}/sandboxes"
        # Establish that BOTH workspaces exist and are accessible to the admin,
        # so a missing workspace cannot count as isolation success.
        check(f"admin accesses {name}", base + path, (200,), token=admin)
        check(
            f"ordinary user {'accesses' if name == allowed else 'is denied in'} {name}",
            base + path,
            (200,) if name == allowed else (403,),
            token=user,
        )
    if other:
        # A 403 can mean the token authenticated but lacks this gateway's role.
        # Only authentication rejection establishes the expected token boundary.
        check(
            "other-gateway token is rejected",
            f"{base}/api/v1/workspaces",
            (401,),
            token=other,
        )
    if cookie:
        data = check(
            "browser session reaches public API",
            f"{public}/api/v1/auth/whoami",
            (200,),
            cookie=cookie,
            ca_file=ca_file,
        )
        if not isinstance(data, dict) or not data.get("subject"):
            failures.append("browser session identity")
    if failures:
        raise ValueError(f"{len(failures)} authorization check(s) failed")
    print(
        "Authorization checks passed. Browser login, grant/revoke, sandbox lifecycle and terminal checks require separate validation."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in (
        "context",
        "namespace",
        "dashboard-url",
        "allowed-workspace",
        "denied-workspace",
        "admin-role",
    ):
        parser.add_argument(f"--{name}", required=True)
    for name in ("admin-token-file", "user-token-file"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    for name in ("other-gateway-token-file", "session-cookie-file", "ca-file"):
        parser.add_argument(f"--{name}", type=Path)
    args = parser.parse_args()
    url = urlsplit(args.dashboard_url)
    if (
        url.scheme != "https"
        or not url.hostname
        or url.username
        or url.password
        or url.path not in ("", "/")
        or url.query
        or url.fragment
    ):
        parser.error("dashboard-url must be an HTTPS origin without credentials")
    if args.allowed_workspace == args.denied_workspace:
        parser.error("allowed and denied workspaces must be different")
    if not shutil.which("kubectl"):
        parser.error("kubectl is required")
    admin = secret_file(args.admin_token_file)
    user = secret_file(args.user_token_file)
    other = (
        secret_file(args.other_gateway_token_file)
        if args.other_gateway_token_file
        else None
    )
    cookie = secret_file(args.session_cookie_file) if args.session_cookie_file else None
    with forward(args.context, args.namespace) as base:
        verify(
            base,
            args.dashboard_url.rstrip("/"),
            admin,
            user,
            args.allowed_workspace,
            args.denied_workspace,
            args.admin_role,
            other,
            cookie,
            args.ca_file,
        )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        print(f"Verification stopped: {error}", file=sys.stderr)
        sys.exit(1)
