#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Keep the e2e image tool versions and Hermeto generic artifacts consistent.

The `ARG <TOOL>_VERSION=` lines in Dockerfile.konflux.e2e-odh are the source
of truth. `--check` (the default, offline) verifies that generic-fetcher.yaml
has exactly one amd64 and one arm64 artifact per tool, with the URL and
filename for the Dockerfile version and a well-formed SHA-256 checksum.
`--update TOOL...` rewrites the artifact list from the Dockerfile versions and
recomputes the checksums of the named tools by downloading both
architectures — concurrently, with retries on transient failures, each hash
checked against a publisher-provided checksum sidecar — use it after Renovate
bumps a version. Other tools keep their recorded checksums. Nothing is written
unless every download succeeds and matches its sidecar.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[3]
DOCKERFILE = ROOT / "deploy/docker/Dockerfile.konflux.e2e-odh"
FETCHER = ROOT / "deploy/konflux/e2e-odh/generic-fetcher.yaml"
ARCHES = ("amd64", "arm64")
_RUST_ARCH = {"amd64": "x86_64", "arm64": "aarch64"}
_GO_ARCH = {"amd64": "amd64", "arm64": "arm64"}


@dataclass(frozen=True)
class Tool:
    arg: str
    url: str
    filename: str
    # URL and asset name recorded in the checksum sidecar. The sidecar is
    # fetched on --update to catch corrupted or inconsistent downloads.
    sidecar: str
    sidecar_filename: str
    arch: dict[str, str]


# Order matches generic-fetcher.yaml. `{v}` is the version, `{a}` the arch.
TOOLS = {
    "uv": Tool(
        "UV_VERSION",
        "https://github.com/astral-sh/uv/releases/download/{v}/uv-{a}-unknown-linux-gnu.tar.gz",
        "uv-{v}-{a}-unknown-linux-gnu.tar.gz",
        "https://github.com/astral-sh/uv/releases/download/{v}/uv-{a}-unknown-linux-gnu.tar.gz.sha256",
        "uv-{a}-unknown-linux-gnu.tar.gz",
        _RUST_ARCH,
    ),
    "oc": Tool(
        "OC_VERSION",
        "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/{v}/openshift-client-linux-{a}-rhel9-{v}.tar.gz",
        "openshift-client-linux-{a}-rhel9-{v}.tar.gz",
        "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/{v}/sha256sum.txt",
        "openshift-client-linux-{a}-rhel9-{v}.tar.gz",
        _GO_ARCH,
    ),
    "helm": Tool(
        "HELM_VERSION",
        "https://get.helm.sh/helm-v{v}-linux-{a}.tar.gz",
        "helm-v{v}-linux-{a}.tar.gz",
        "https://get.helm.sh/helm-v{v}-linux-{a}.tar.gz.sha256sum",
        "helm-v{v}-linux-{a}.tar.gz",
        _GO_ARCH,
    ),
    "nextest": Tool(
        "NEXTEST_VERSION",
        "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-{v}/cargo-nextest-{v}-{a}-unknown-linux-gnu.tar.gz",
        "cargo-nextest-{v}-{a}-unknown-linux-gnu.tar.gz",
        "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-{v}/cargo-nextest-{v}-{a}-unknown-linux-gnu.sha256",
        "cargo-nextest-{v}-{a}-unknown-linux-gnu.tar.gz",
        _RUST_ARCH,
    ),
}

_ARG = re.compile(r"^ARG (?P<name>[A-Z_]+)=(?P<value>\S+)$", re.MULTILINE)
_ARTIFACT = re.compile(
    r'^  - download_url: (?P<url>\S+)\n    checksum: "(?P<checksum>[^"]+)"\n    filename: (?P<filename>\S+)$',
    re.MULTILINE,
)
_CHECKSUM = re.compile(r"sha256:[0-9a-f]{64}\Z")
_VERSION = re.compile(r"[0-9A-Za-z.+-]+\Z")


def require_https(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme.lower() != "https" or not parsed.netloc:
        raise ValueError(f"refusing non-HTTPS URL: {url}")


class HTTPSRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require_https(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


@dataclass(frozen=True)
class Artifact:
    url: str
    checksum: str
    filename: str


def read_versions(dockerfile: Path = DOCKERFILE) -> dict[str, str]:
    args = {m["name"]: m["value"] for m in _ARG.finditer(dockerfile.read_text())}
    versions = {}
    for name, tool in TOOLS.items():
        version = args.get(tool.arg)
        if version is None or not _VERSION.fullmatch(version):
            raise SystemExit(f"{dockerfile}: missing or invalid ARG {tool.arg}")
        versions[name] = version
    return versions


def read_fetcher(fetcher: Path = FETCHER) -> tuple[str, list[Artifact]]:
    text = fetcher.read_text()
    header, sep, body = text.partition("artifacts:\n")
    if not sep:
        raise SystemExit(f"{fetcher}: missing 'artifacts:' list")
    artifacts = [
        Artifact(m["url"], m["checksum"], m["filename"])
        for m in _ARTIFACT.finditer(body)
    ]
    entries = body.count("- download_url:")
    if entries != len(artifacts):
        raise SystemExit(
            f"{fetcher}: {entries - len(artifacts)} artifact(s) do not use the url/checksum/filename layout"
        )
    return header + sep, artifacts


def expected(name: str, version: str, arch: str) -> tuple[str, str, str, str]:
    tool = TOOLS[name]
    values = {"v": version, "a": tool.arch[arch]}
    return (
        tool.url.format(**values),
        tool.filename.format(**values),
        tool.sidecar.format(**values),
        tool.sidecar_filename.format(**values),
    )


def filename_pattern(name: str, arch: str) -> re.Pattern[str]:
    """Match the tool's artifact filename for an arch at any version."""
    tool = TOOLS[name]
    escaped = re.escape(tool.filename).replace(
        re.escape("{a}"), re.escape(tool.arch[arch])
    )
    return re.compile(escaped.replace(re.escape("{v}"), r"[0-9A-Za-z.+-]+"))


def check(versions: dict[str, str], artifacts: list[Artifact]) -> list[str]:
    errors = []
    claimed: set[int] = set()
    for name in TOOLS:
        for arch in ARCHES:
            url, filename, _, _ = expected(name, versions[name], arch)
            matches = [
                i
                for i, a in enumerate(artifacts)
                if a.url == url and a.filename == filename
            ]
            claimed.update(matches)
            if len(matches) != 1:
                stale = [
                    a.filename
                    for a in artifacts
                    if a.filename != filename
                    and filename_pattern(name, arch).fullmatch(a.filename)
                ]
                hint = f"; found {', '.join(stale)}" if stale else ""
                errors.append(
                    f"{name} {arch}: expected exactly one artifact for {versions[name]} ({filename}), found {len(matches)}{hint}"
                )
                continue
            checksum = artifacts[matches[0]].checksum
            if not _CHECKSUM.fullmatch(checksum):
                errors.append(f"{name} {arch}: malformed checksum {checksum!r}")
    errors.extend(
        f"unexpected artifact not derived from the Dockerfile: {a.filename}"
        for i, a in enumerate(artifacts)
        if i not in claimed
    )
    return errors


RETRY_ATTEMPTS = 3
MAX_RETRY_AFTER_SECONDS = 60


def retry_delay(retry_after: str | None, attempt: int) -> int:
    """Return a bounded Retry-After delay or the exponential fallback."""
    fallback_delay = 2 ** (attempt - 1)
    if not retry_after or not retry_after.isascii() or not retry_after.isdecimal():
        return fallback_delay

    significant_digits = retry_after.lstrip("0")
    if len(significant_digits) > len(str(MAX_RETRY_AFTER_SECONDS)):
        return MAX_RETRY_AFTER_SECONDS
    return min(int(significant_digits or "0"), MAX_RETRY_AFTER_SECONDS)


def _with_retry(url: str, consume, what: str):
    """Run `consume` on `url`'s response, retrying transient failures.

    HTTP 4xx (other than rate limiting) is permanent and raises immediately;
    connection errors, timeouts, HTTP 429, and HTTP 5xx are retried.
    """
    require_https(url)
    for attempt in range(1, RETRY_ATTEMPTS + 1):
        try:
            opener = urllib.request.build_opener(HTTPSRedirectHandler())
            with opener.open(url, timeout=120) as response:
                return consume(response)
        except urllib.error.HTTPError as err:
            # Client errors are permanent; the mirror hiccuping is not.
            if (400 <= err.code < 500 and err.code != 429) or attempt == RETRY_ATTEMPTS:
                raise
            last_error: Exception = err
        except (urllib.error.URLError, TimeoutError, OSError) as err:
            if attempt == RETRY_ATTEMPTS:
                raise
            last_error = err
        retry_after = (
            last_error.headers.get("Retry-After")
            if isinstance(last_error, urllib.error.HTTPError)
            else None
        )
        delay = retry_delay(retry_after, attempt)
        print(
            f"{url}: {last_error}; attempt {attempt}/{RETRY_ATTEMPTS} failed "
            f"while {what}, retrying in {delay}s",
            file=sys.stderr,
        )
        time.sleep(delay)
    raise AssertionError("unreachable")


def sha256_of(url: str) -> str:
    """Download `url` and return its `sha256:` checksum."""

    def consume(response):
        # _with_retry invokes this once per response. The digest must be
        # per-attempt too: a partial failed download cannot contaminate the
        # checksum of a complete retry.
        digest = hashlib.sha256()
        for chunk in iter(lambda: response.read(1 << 20), b""):
            digest.update(chunk)
        return f"sha256:{digest.hexdigest()}"

    return _with_retry(url, consume, "hashing the download")


def fetch_text(url: str) -> str:
    """Download `url` and return its body as text."""
    return _with_retry(
        url, lambda response: response.read().decode(), "fetching the sidecar"
    )


def published_checksum(sidecar_url: str, filename: str) -> str:
    """Return the checksum a publisher sidecar records for `filename`."""
    text = fetch_text(sidecar_url)
    lines = [line for line in text.splitlines() if line.strip()]
    for line in lines:
        parts = line.split()
        if len(parts) >= 2 and parts[1].lstrip("*") == filename:
            return f"sha256:{parts[0]}"
    raise SystemExit(f"{sidecar_url}: no checksum recorded for {filename}")


def download_verified(url: str, sidecar_url: str, filename: str) -> str:
    """Download `url`, hash it, and verify the hash against the sidecar.

    The check catches corruption or an inconsistent artifact/sidecar response;
    it does not make the sidecar, which comes from the same publisher origin,
    an independent trust root.
    """
    checksum = sha256_of(url)
    published = published_checksum(sidecar_url, filename)
    if checksum != published:
        raise SystemExit(
            f"{url}: downloaded checksum {checksum} does not match the "
            f"published {published} — refusing to bless a substituted artifact"
        )
    return checksum


def render(header: str, artifacts: list[list[Artifact]]) -> str:
    groups = [
        "".join(
            f'  - download_url: {a.url}\n    checksum: "{a.checksum}"\n    filename: {a.filename}\n'
            for a in group
        )
        for group in artifacts
    ]
    return header + "\n".join(groups)


def known_artifact(artifact: Artifact) -> bool:
    """True if the artifact belongs to a tool in TOOLS at some version.

    Old-version artifacts of a tool being updated match their tool's
    filename pattern and are legitimately replaced; an artifact no tool
    declares would be silently dropped by the rewrite.
    """
    return any(
        filename_pattern(name, arch).fullmatch(artifact.filename)
        for name in TOOLS
        for arch in ARCHES
    )


def update(
    versions: dict[str, str], header: str, artifacts: list[Artifact], tools: list[str]
) -> str:
    # Refuse to rewrite while the file holds artifacts no tool declares:
    # the rewrite regenerates the list from TOOLS and would delete them
    # without any signal to the maintainer running the Renovate note.
    unknown = [a for a in artifacts if not known_artifact(a)]
    if unknown:
        listing = "\n".join(f"  {a.filename} ({a.url})" for a in unknown)
        raise SystemExit(
            "generic-fetcher.yaml holds artifacts no tool in TOOLS declares:\n"
            f"{listing}\n"
            "Refusing to rewrite. Extend TOOLS or remove the artifacts first."
        )
    recorded = {a.url: a.checksum for a in artifacts}
    # Resolve which URLs need downloading before touching the network, so a
    # missing recorded checksum for an untouched tool fails before any
    # transfer starts.
    jobs: dict[str, tuple[str, str]] = {}  # url -> (sidecar_url, filename)
    for name in TOOLS:
        for arch in ARCHES:
            url, _, sidecar, sidecar_filename = expected(name, versions[name], arch)
            if name in tools:
                jobs[url] = (sidecar, sidecar_filename)
            elif url not in recorded:
                raise SystemExit(
                    f"{name} {arch}: no recorded checksum for {url}; run --update {name}"
                )
    checksums: dict[str, str] = {}
    if jobs:
        for url in jobs:
            print(f"Downloading {url}", file=sys.stderr)
        # The downloads share no state and nothing is written until every
        # checksum exists, so they run concurrently: wall time is the
        # slowest artifact, not the sum of all transfers. A failure in any
        # future re-raised below aborts before write_atomically runs.
        with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
            futures = {
                pool.submit(download_verified, url, sidecar, filename): url
                for url, (sidecar, filename) in jobs.items()
            }
            for future in as_completed(futures):
                checksums[futures[future]] = future.result()
    groups = []
    for name in TOOLS:
        group = []
        for arch in ARCHES:
            url, filename, _, _ = expected(name, versions[name], arch)
            checksum = checksums[url] if url in checksums else recorded[url]
            group.append(Artifact(url, checksum, filename))
        groups.append(group)
    return render(header, groups)


def write_atomically(path: Path, text: str) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        Path(tmp).chmod(path.stat().st_mode & 0o777)
        Path(tmp).replace(path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check", action="store_true", help="verify consistency offline (default)"
    )
    mode.add_argument(
        "--update",
        nargs="+",
        metavar="TOOL",
        choices=[*TOOLS, "all"],
        help="rewrite artifacts and re-hash TOOL",
    )
    parser.add_argument(
        "--dockerfile", type=Path, default=DOCKERFILE, help=argparse.SUPPRESS
    )
    parser.add_argument("--fetcher", type=Path, default=FETCHER, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    versions = read_versions(args.dockerfile)
    header, artifacts = read_fetcher(args.fetcher)
    if args.update:
        tools = list(TOOLS) if "all" in args.update else args.update
        write_atomically(args.fetcher, update(versions, header, artifacts, tools))
        header, artifacts = read_fetcher(args.fetcher)

    errors = check(versions, artifacts)
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        print(
            f"Fix {args.fetcher.name} or run {Path(__file__).name} --update <tool>",
            file=sys.stderr,
        )
        return 1
    print(
        f"{args.fetcher.name} matches {args.dockerfile.name} for {', '.join(TOOLS)} (amd64, arm64)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
