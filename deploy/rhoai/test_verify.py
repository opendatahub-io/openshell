# SPDX-FileCopyrightText: Copyright (c) 2026 OpenShell contributors
# SPDX-License-Identifier: Apache-2.0
"""Authorization verifier regression tests; no cluster or identity provider."""

import importlib.util
import io
import threading
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location(
    "verifier", Path(__file__).with_name("verify.py")
)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class VerifyTests(unittest.TestCase):
    def response(self, url, token=None, **_kwargs):
        if url.startswith("https:") or not token:
            return 401, None
        if url.endswith("whoami"):
            return 200, {
                "subject": token,
                "roles": ["admin"] if token == "admin-token" else ["user"],
            }
        if token == "other-token":
            return 401, None
        if token == "user-token" and "/private/" in url:
            return 403, None
        return 200, []

    def run_verify(self, http):
        with redirect_stdout(io.StringIO()) as output:
            verifier.verify(
                "http://127.0.0.1:1234",
                "https://dashboard.example",
                "admin-token",
                "user-token",
                "team",
                "private",
                "admin",
                other="other-token",
                http=http,
            )
        self.assertNotIn("admin-token", output.getvalue())
        self.assertNotIn("user-token", output.getvalue())

    def test_allowed_and_denied_access(self):
        self.run_verify(self.response)

    def test_other_gateway_token_forbidden_does_not_prove_audience_isolation(self):
        def response(url, token=None, **kwargs):
            if token == "other-token":
                # A shared-issuer, multi-audience token authenticated, but lacks
                # this gateway's required role. That is not audience rejection.
                return 403, None
            return self.response(url, token, **kwargs)

        with self.assertRaisesRegex(ValueError, "1 authorization check"):
            self.run_verify(response)

    def test_false_positive_authorization_results_fail(self):
        for failure in (
            "admin",
            "user",
            "missing-workspace",
            "public-redirect",
            "missing-subject",
            "wrong-audience",
        ):

            def response(url, token=None, failure=failure, **kwargs):
                if failure == "admin" and token == "admin-token":
                    return 403, None
                if failure == "user" and token == "user-token" and "/private/" in url:
                    return 200, []
                if failure == "missing-workspace" and "/private/" in url:
                    return 404, None
                if failure == "public-redirect" and url.startswith("https:"):
                    return 302, None
                if failure == "missing-subject" and url.endswith("whoami"):
                    return 200, {"roles": ["admin"]}
                if failure == "wrong-audience" and token == "other-token":
                    return 200, []
                return self.response(url, token, **kwargs)

            with self.subTest(failure=failure), self.assertRaises(ValueError):
                self.run_verify(response)

    def test_redirect_does_not_forward_credentials(self):
        received = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                received.append((self.path, self.headers.get("Authorization")))
                self.send_response(302)
                self.send_header("Location", "/leak")
                self.end_headers()

            def log_message(self, *_args):
                pass

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                status, _ = verifier.request(
                    f"http://127.0.0.1:{server.server_port}/start",
                    token="private-token",
                )
                self.assertEqual(status, 302)
                self.assertEqual(received, [("/start", "Bearer private-token")])
            finally:
                server.shutdown()
                thread.join()

    def test_port_forward_is_terminated_when_verification_fails(self):
        process = Mock()
        process.poll.return_value = None

        def start(_args, stdout, **_kwargs):
            stdout.write("Forwarding from 127.0.0.1:4567 -> 8080\n")
            stdout.flush()
            return process

        with (
            patch.object(verifier.subprocess, "Popen", side_effect=start),
            self.assertRaisesRegex(ValueError, "test failure"),
            verifier.forward("context", "team") as url,
        ):
            self.assertEqual(url, "http://127.0.0.1:4567")
            raise ValueError("test failure")
        process.terminate.assert_called_once()
        process.wait.assert_called_once()


if __name__ == "__main__":
    unittest.main()
