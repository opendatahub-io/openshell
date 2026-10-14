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
architectures; use it after Renovate bumps a version. Other tools keep their
recorded checksums. Nothing is written unless every download succeeds.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import tempfile
import urllib.request
from urllib.parse import urlparse
from dataclasses import dataclass
from pathlib import Path

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
    arch: dict[str, str]


# Order matches generic-fetcher.yaml. `{v}` is the version, `{a}` the arch.
TOOLS = {
    "uv": Tool(
        "UV_VERSION",
        "https://github.com/astral-sh/uv/releases/download/{v}/uv-{a}-unknown-linux-gnu.tar.gz",
        "uv-{v}-{a}-unknown-linux-gnu.tar.gz",
        _RUST_ARCH,
    ),
    "oc": Tool(
        "OC_VERSION",
        "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/{v}/openshift-client-linux-{a}-rhel9-{v}.tar.gz",
        "openshift-client-linux-{a}-rhel9-{v}.tar.gz",
        _GO_ARCH,
    ),
    "helm": Tool(
        "HELM_VERSION",
        "https://get.helm.sh/helm-v{v}-linux-{a}.tar.gz",
        "helm-v{v}-linux-{a}.tar.gz",
        _GO_ARCH,
    ),
    "nextest": Tool(
        "NEXTEST_VERSION",
        "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-{v}/cargo-nextest-{v}-{a}-unknown-linux-gnu.tar.gz",
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


def expected(name: str, version: str, arch: str) -> tuple[str, str]:
    tool = TOOLS[name]
    values = {"v": version, "a": tool.arch[arch]}
    return tool.url.format(**values), tool.filename.format(**values)


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
            url, filename = expected(name, versions[name], arch)
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


def sha256_of(url: str) -> str:
    require_https(url)
    digest = hashlib.sha256()
    opener = urllib.request.build_opener(HTTPSRedirectHandler())
    with opener.open(url, timeout=120) as response:
        for chunk in iter(lambda: response.read(1 << 20), b""):
            digest.update(chunk)
    return f"sha256:{digest.hexdigest()}"


def render(header: str, artifacts: list[list[Artifact]]) -> str:
    groups = [
        "".join(
            f'  - download_url: {a.url}\n    checksum: "{a.checksum}"\n    filename: {a.filename}\n'
            for a in group
        )
        for group in artifacts
    ]
    return header + "\n".join(groups)


def update(
    versions: dict[str, str], header: str, artifacts: list[Artifact], tools: list[str]
) -> str:
    recorded = {a.url: a.checksum for a in artifacts}
    groups = []
    for name in TOOLS:
        group = []
        for arch in ARCHES:
            url, filename = expected(name, versions[name], arch)
            if name in tools:
                print(f"Downloading {url}", file=sys.stderr)
                checksum = sha256_of(url)
            elif url in recorded:
                checksum = recorded[url]
            else:
                raise SystemExit(
                    f"{name} {arch}: no recorded checksum for {url}; run --update {name}"
                )
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
