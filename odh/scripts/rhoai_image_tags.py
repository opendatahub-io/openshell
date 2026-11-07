#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Point RHOAI e2e branches at the latest midstream vX.Y.Z-rhaiv.N commit.

Each mapping key is a git branch and the Konflux image tag
quay.io/opendatahub/odh-openshell-e2e:<branch>. While midstream keeps
minting v0.1.5-rhaiv.N, every stream mapped to v0.1.5 moves with the
latest N. After v0.1.6-rhaiv.0 exists, those v0.1.5 rows stay on the last
v0.1.5-rhaiv.N because rhaiv-auto-tag stops incrementing the old train.

This script only pushes git refs. Konflux builds and pushes Quay.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

PRODUCT_TAG_RE = re.compile(r"^rhoai-[0-9]+\.[0-9]+(?:-ea\.[0-9]+)?-e2e$")
OPENSHELL_VERSION_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
RHAIV_TAG_RE = re.compile(r"^(v[0-9]+\.[0-9]+\.[0-9]+)-rhaiv\.([0-9]+)$")
DEFAULT_MAPPING = (
    Path(__file__).resolve().parents[1] / "rhoai-image-tags.yaml"
)
PIPELINERUN_COMMIT_MESSAGE = (
    "ci(odh): ensure e2e RHOAI Konflux PipelineRun\n"
    "\n"
    "Signed-off-by: github-actions[bot] "
    "<github-actions[bot]@users.noreply.github.com>\n"
)


@dataclass(frozen=True)
class MappingConfig:
    tags: dict[str, str]


@dataclass(frozen=True)
class BranchPlan:
    branch: str
    version: str
    rhaiv_tag: str


def load_mapping(path: Path) -> MappingConfig:
    tags: dict[str, str] = {}
    section: str | None = None
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line == "tags:":
            section = "tags"
            continue
        if section == "tags":
            match = re.fullmatch(r"  (\S+): (\S+)", line)
            if match is None:
                raise ValueError(f"{path}:{lineno}: expected product tag mapping")
            product, version = match.group(1), match.group(2)
            if PRODUCT_TAG_RE.fullmatch(product) is None:
                raise ValueError(f"{path}:{lineno}: invalid product tag {product!r}")
            if OPENSHELL_VERSION_RE.fullmatch(version) is None:
                raise ValueError(f"{path}:{lineno}: invalid OpenShell version {version!r}")
            if product in tags:
                raise ValueError(f"{path}:{lineno}: duplicate product tag {product}")
            tags[product] = version
            continue
        raise ValueError(f"{path}:{lineno}: unknown mapping key {line!r}")
    if not tags:
        raise ValueError(f"{path}: at least one product tag is required")
    return MappingConfig(tags=tags)


def parse_rhaiv_tag(tag: str) -> tuple[str, int]:
    match = RHAIV_TAG_RE.fullmatch(tag)
    if match is None:
        raise ValueError(f"invalid rhaiv tag {tag!r}")
    n_text = match.group(2)
    if n_text != str(int(n_text)):
        raise ValueError(f"invalid rhaiv tag {tag!r}")
    return match.group(1), int(n_text)


def latest_rhaiv_for_version(tags: tuple[str, ...] | list[str], version: str) -> str | None:
    latest: tuple[int, str] | None = None
    for tag in tags:
        try:
            tag_version, n = parse_rhaiv_tag(tag)
        except ValueError:
            continue
        if tag_version != version:
            continue
        if latest is None or n > latest[0]:
            latest = (n, tag)
    return None if latest is None else latest[1]


def plan_branches(
    config: MappingConfig,
    rhaiv_tags: tuple[str, ...] | list[str],
    from_rhaiv: str | None = None,
) -> tuple[tuple[BranchPlan, ...], tuple[tuple[str, str], ...]]:
    planned: list[BranchPlan] = []
    skipped: list[tuple[str, str]] = []
    if from_rhaiv is not None:
        version, _ = parse_rhaiv_tag(from_rhaiv)
        source_tag = from_rhaiv
        products = [
            product for product, mapped in config.tags.items() if mapped == version
        ]
    else:
        source_tag = None
        products = list(config.tags)
    for product in products:
        version = config.tags[product]
        source = source_tag if source_tag is not None else latest_rhaiv_for_version(
            rhaiv_tags, version
        )
        if source is None:
            skipped.append((product, version))
            continue
        planned.append(
            BranchPlan(branch=product, version=version, rhaiv_tag=source)
        )
    return tuple(planned), tuple(skipped)


def git_rhaiv_tags(repo: Path) -> tuple[str, ...]:
    completed = _git(["tag", "-l", "v*-rhaiv.*"], cwd=repo)
    tags: list[str] = []
    for line in completed.stdout.splitlines():
        tag = line.strip()
        if not tag:
            continue
        try:
            parse_rhaiv_tag(tag)
        except ValueError:
            continue
        tags.append(tag)
    return tuple(tags)


def _git(
    args: list[str],
    *,
    cwd: Path,
    check: bool = True,
    input_text: str | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
        input=input_text,
        env=env,
    )
    if check and completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"git {' '.join(args)} failed: {detail}")
    return completed


def git_commit_sha(repo: Path, rev: str) -> str:
    return _git(["rev-parse", f"{rev}^{{commit}}"], cwd=repo).stdout.strip()


def git_remote_branch_sha(repo: Path, remote: str, branch: str) -> str | None:
    completed = _git(
        ["rev-parse", "--verify", f"refs/remotes/{remote}/{branch}^{{commit}}"],
        cwd=repo,
        check=False,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def git_parent_sha(repo: Path, sha: str) -> str | None:
    completed = _git(["rev-parse", "--verify", f"{sha}^"], cwd=repo, check=False)
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def git_file_at(repo: Path, sha: str, rel: str) -> str | None:
    completed = _git(["show", f"{sha}:{rel}"], cwd=repo, check=False)
    if completed.returncode != 0:
        return None
    return completed.stdout


def fetch_rhoai_branches(repo: Path, remote: str) -> None:
    _git(
        [
            "fetch",
            remote,
            f"+refs/heads/rhoai-*:refs/remotes/{remote}/rhoai-*",
        ],
        cwd=repo,
        check=False,
    )


def commit_file_on_base(
    repo: Path, base_sha: str, rel: str, content: str, message: str
) -> str:
    blob = _git(
        ["hash-object", "-w", "--stdin"],
        cwd=repo,
        input_text=content,
    ).stdout.strip()
    index_path = tempfile.NamedTemporaryFile(delete=False)
    index_path.close()
    env = os.environ.copy()
    env["GIT_INDEX_FILE"] = index_path.name
    try:
        _git(["read-tree", base_sha], cwd=repo, env=env)
        _git(
            ["update-index", "--add", "--cacheinfo", f"100644,{blob},{rel}"],
            cwd=repo,
            env=env,
        )
        tree = _git(["write-tree"], cwd=repo, env=env).stdout.strip()
    finally:
        os.unlink(index_path.name)
    return _git(
        ["commit-tree", tree, "-p", base_sha, "-m", message],
        cwd=repo,
    ).stdout.strip()


def resolve_push_sha(
    repo: Path,
    base_sha: str,
    current_sha: str | None,
    pipelinerun_rel: str | None,
    pipelinerun_content: str | None,
) -> str:
    if pipelinerun_rel is None or pipelinerun_content is None:
        return base_sha
    if git_file_at(repo, base_sha, pipelinerun_rel) == pipelinerun_content:
        return base_sha
    if current_sha is not None:
        parent = git_parent_sha(repo, current_sha)
        if (
            parent == base_sha
            and git_file_at(repo, current_sha, pipelinerun_rel) == pipelinerun_content
        ):
            return current_sha
    return commit_file_on_base(
        repo,
        base_sha,
        pipelinerun_rel,
        pipelinerun_content,
        PIPELINERUN_COMMIT_MESSAGE,
    )


def push_branch(
    repo: Path, remote: str, sha: str, branch: str, current_sha: str | None
) -> None:
    refspec = f"{sha}:refs/heads/{branch}"
    if current_sha is None:
        _git(["push", remote, refspec], cwd=repo)
        return
    _git(
        [
            "push",
            f"--force-with-lease=refs/heads/{branch}:{current_sha}",
            remote,
            refspec,
        ],
        cwd=repo,
    )


def apply_branches(
    repo: Path,
    planned: tuple[BranchPlan, ...],
    skipped: tuple[tuple[str, str], ...],
    *,
    dry_run: bool,
    remote: str,
    pipelinerun: Path | None,
) -> int:
    pipelinerun_rel: str | None = None
    pipelinerun_content: str | None = None
    if pipelinerun is not None:
        pipelinerun_rel = pipelinerun.resolve().relative_to(repo.resolve()).as_posix()
        pipelinerun_content = pipelinerun.read_text(encoding="utf-8")
    if not dry_run:
        fetch_rhoai_branches(repo, remote)
    created = 0
    updated = 0
    unchanged = 0
    for item in planned:
        print(f"{item.branch} <- {item.rhaiv_tag} ({item.version})")
        if dry_run:
            continue
        base_sha = git_commit_sha(repo, item.rhaiv_tag)
        current_sha = git_remote_branch_sha(repo, remote, item.branch)
        want_sha = resolve_push_sha(
            repo,
            base_sha,
            current_sha,
            pipelinerun_rel,
            pipelinerun_content,
        )
        if current_sha == want_sha:
            print(f"unchanged {item.branch} at {want_sha}")
            unchanged += 1
            continue
        push_branch(repo, remote, want_sha, item.branch, current_sha)
        if current_sha is None:
            print(f"created {item.branch} at {want_sha}")
            created += 1
        else:
            print(f"updated {item.branch} {current_sha} -> {want_sha}")
            updated += 1
    for branch, version in skipped:
        print(f"skip {branch}: no rhaiv tag for {version}")
    print(
        f"created={created} updated={updated} unchanged={unchanged} "
        f"skipped_missing={len(skipped)} planned={len(planned)}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mapping",
        type=Path,
        default=DEFAULT_MAPPING,
        help="Product branch mapping YAML",
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="Git repo used to list rhaiv tags and push branches",
    )
    parser.add_argument(
        "--remote",
        default="origin",
        help="Git remote that receives rhoai-*-e2e branches",
    )
    parser.add_argument(
        "--from-rhaiv",
        default=None,
        help="Move only streams mapped to this exact rhaiv tag's OpenShell version",
    )
    parser.add_argument(
        "--ensure-pipelinerun",
        type=Path,
        default=None,
        help=(
            "If the rhaiv commit lacks this PipelineRun file, commit the "
            "working-tree copy on top so Konflux PAC can build the branch"
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the branch plan without pushing",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Create or update rhoai-*-e2e branches",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    config = load_mapping(args.mapping)
    rhaiv_tags = git_rhaiv_tags(args.repo)
    planned, skipped = plan_branches(config, rhaiv_tags, from_rhaiv=args.from_rhaiv)
    if not args.apply:
        args.dry_run = True
    pipelinerun = args.ensure_pipelinerun
    if pipelinerun is not None and not pipelinerun.is_absolute():
        pipelinerun = args.repo / pipelinerun
    return apply_branches(
        args.repo,
        planned,
        skipped,
        dry_run=args.dry_run or not args.apply,
        remote=args.remote,
        pipelinerun=pipelinerun,
    )


if __name__ == "__main__":
    sys.exit(main())
