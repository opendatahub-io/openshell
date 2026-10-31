# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Regression tests for the generic-fetcher checksum synchronizer."""

from __future__ import annotations

import hashlib
import importlib.util
import sys
import unittest
from email.message import Message
from pathlib import Path
from unittest.mock import call, patch
from urllib.error import HTTPError


def _load_module():
    path = Path(__file__).with_name("sync-generic-fetcher.py")
    spec = importlib.util.spec_from_file_location("sync_generic_fetcher", path)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


sync_generic_fetcher = _load_module()


class _Response:
    def __init__(self, chunks: list[bytes | Exception]):
        self._chunks = iter(chunks)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, _size: int) -> bytes:
        chunk = next(self._chunks)
        if isinstance(chunk, Exception):
            raise chunk
        return chunk


class _Opener:
    def __init__(self, responses: list[_Response | Exception]):
        self._responses = iter(responses)

    def open(self, _url: str, timeout: int):
        assert timeout == 120
        response = next(self._responses)
        if isinstance(response, Exception):
            raise response
        return response


class SyncGenericFetcherTests(unittest.TestCase):
    def test_sha256_of_retries_with_a_fresh_hash(self) -> None:
        complete = b"the complete retry response"
        opener = _Opener(
            [
                _Response([b"partial first response", OSError("interrupted")]),
                _Response([complete, b""]),
            ]
        )
        with (
            patch.object(
                sync_generic_fetcher.urllib.request,
                "build_opener",
                return_value=opener,
            ),
            patch.object(sync_generic_fetcher.time, "sleep"),
        ):
            checksum = sync_generic_fetcher.sha256_of("https://example.test/artifact")

        self.assertEqual(checksum, f"sha256:{hashlib.sha256(complete).hexdigest()}")

    def test_retry_after_is_honored_for_rate_limiting(self) -> None:
        for retry_after in ("7", "10"):
            with self.subTest(retry_after=retry_after):
                headers = Message()
                headers["Retry-After"] = retry_after
                rate_limited = HTTPError(
                    "https://example.test/artifact", 429, "rate limited", headers, None
                )
                complete = b"complete retry response"
                opener = _Opener([rate_limited, _Response([complete, b""])])
                with (
                    patch.object(
                        sync_generic_fetcher.urllib.request,
                        "build_opener",
                        return_value=opener,
                    ),
                    patch.object(sync_generic_fetcher.time, "sleep") as sleep,
                ):
                    checksum = sync_generic_fetcher.sha256_of(
                        "https://example.test/artifact"
                    )

                self.assertEqual(
                    checksum, f"sha256:{hashlib.sha256(complete).hexdigest()}"
                )
                sleep.assert_called_once_with(int(retry_after))

    def test_retry_after_is_capped_for_rate_limiting(self) -> None:
        for retry_after in ("3600", "9" * 10_000):
            with self.subTest(retry_after=retry_after[:4]):
                headers = Message()
                headers["Retry-After"] = retry_after
                rate_limited = HTTPError(
                    "https://example.test/artifact", 429, "rate limited", headers, None
                )
                complete = b"complete retry response"
                opener = _Opener([rate_limited, _Response([complete, b""])])
                with (
                    patch.object(
                        sync_generic_fetcher.urllib.request,
                        "build_opener",
                        return_value=opener,
                    ),
                    patch.object(sync_generic_fetcher.time, "sleep") as sleep,
                ):
                    sync_generic_fetcher.sha256_of("https://example.test/artifact")

                sleep.assert_called_once_with(60)

    def test_retry_after_falls_back_to_exponential_backoff_when_invalid(self) -> None:
        for retry_after in (None, "later", "²", "\N{ARABIC-INDIC DIGIT SEVEN}"):
            with self.subTest(retry_after=retry_after):
                headers = Message()
                if retry_after is not None:
                    headers["Retry-After"] = retry_after
                rate_limited = HTTPError(
                    "https://example.test/artifact",
                    429,
                    "rate limited",
                    headers,
                    None,
                )
                opener = _Opener(
                    [rate_limited, _Response([b"complete retry response", b""])]
                )
                with (
                    patch.object(
                        sync_generic_fetcher.urllib.request,
                        "build_opener",
                        return_value=opener,
                    ),
                    patch.object(sync_generic_fetcher.time, "sleep") as sleep,
                ):
                    sync_generic_fetcher.sha256_of("https://example.test/artifact")

                sleep.assert_called_once_with(1)

    def test_retry_after_fallback_doubles_on_consecutive_retries(self) -> None:
        rate_limited_responses = [
            HTTPError(
                "https://example.test/artifact", 429, "rate limited", Message(), None
            )
            for _ in range(2)
        ]
        opener = _Opener(
            [*rate_limited_responses, _Response([b"complete retry response", b""])]
        )
        with (
            patch.object(
                sync_generic_fetcher.urllib.request,
                "build_opener",
                return_value=opener,
            ),
            patch.object(sync_generic_fetcher.time, "sleep") as sleep,
        ):
            sync_generic_fetcher.sha256_of("https://example.test/artifact")

        self.assertEqual(sleep.call_args_list, [call(1), call(2)])

    def test_published_checksum_requires_the_sidecar_asset_name(self) -> None:
        with (
            patch.object(
                sync_generic_fetcher,
                "fetch_text",
                return_value="a" * 64 + "  unexpected-asset.tar.gz\n",
            ),
            self.assertRaisesRegex(
                SystemExit, "no checksum recorded for expected-asset.tar.gz"
            ),
        ):
            sync_generic_fetcher.published_checksum(
                "https://example.test/artifact.sha256", "expected-asset.tar.gz"
            )

    def test_uv_sidecar_accepts_its_unversioned_asset_name(self) -> None:
        _, versioned_filename, sidecar_url, sidecar_filename = (
            sync_generic_fetcher.expected("uv", "0.13.1", "amd64")
        )
        self.assertNotEqual(versioned_filename, sidecar_filename)
        expected_checksum = "sha256:" + "a" * 64
        with patch.object(
            sync_generic_fetcher,
            "fetch_text",
            return_value=f"{'a' * 64}  {sidecar_filename}\n",
        ):
            checksum = sync_generic_fetcher.published_checksum(
                sidecar_url, sidecar_filename
            )

        self.assertEqual(checksum, expected_checksum)


if __name__ == "__main__":
    unittest.main()
