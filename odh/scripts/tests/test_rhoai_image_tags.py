#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for RHOAI e2e branch mapping against midstream rhaiv tags."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import rhoai_image_tags  # noqa: E402


VALID_MAPPING = """\
tags:
  rhoai-3.6-e2e: v0.1.3
  rhoai-3.7-ea.1-e2e: v0.1.5
  rhoai-3.7-ea.2-e2e: v0.1.5
  rhoai-3.7-e2e: v0.1.6
"""

PIPELINERUN = "apiVersion: tekton.dev/v1\nkind: PipelineRun\n"


def write_mapping(text: str) -> Path:
    directory = Path(tempfile.mkdtemp())
    path = directory / "rhoai-image-tags.yaml"
    path.write_text(text, encoding="utf-8")
    return path


def git(args: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=check,
        capture_output=True,
        text=True,
    )


def init_repo() -> Path:
    repo = Path(tempfile.mkdtemp()) / "src"
    repo.mkdir()
    git(["init", "-b", "main"], cwd=repo)
    git(["config", "user.email", "test@example.com"], cwd=repo)
    git(["config", "user.name", "Test"], cwd=repo)
    (repo / "README").write_text("src\n", encoding="utf-8")
    git(["add", "README"], cwd=repo)
    git(["commit", "-m", "init"], cwd=repo)
    return repo


class LoadMappingTests(unittest.TestCase):
    def test_loads_product_tags(self) -> None:
        config = rhoai_image_tags.load_mapping(write_mapping(VALID_MAPPING))
        self.assertEqual(
            config.tags,
            {
                "rhoai-3.6-e2e": "v0.1.3",
                "rhoai-3.7-ea.1-e2e": "v0.1.5",
                "rhoai-3.7-ea.2-e2e": "v0.1.5",
                "rhoai-3.7-e2e": "v0.1.6",
            },
        )

    def test_rejects_unknown_section(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown mapping key"):
            rhoai_image_tags.load_mapping(write_mapping("foo: bar\n"))

    def test_rejects_tag_without_e2e_suffix(self) -> None:
        text = """\
tags:
  rhoai-3.7-ea.1: v0.1.5
"""
        with self.assertRaisesRegex(ValueError, "invalid product tag"):
            rhoai_image_tags.load_mapping(write_mapping(text))

    def test_rejects_duplicate_product_tag(self) -> None:
        text = """\
tags:
  rhoai-3.7-e2e: v0.1.5
  rhoai-3.7-e2e: v0.1.6
"""
        with self.assertRaisesRegex(ValueError, "duplicate product tag"):
            rhoai_image_tags.load_mapping(write_mapping(text))

    def test_repo_mapping_file_loads(self) -> None:
        path = Path(__file__).resolve().parents[2] / "rhoai-image-tags.yaml"
        config = rhoai_image_tags.load_mapping(path)
        self.assertTrue(config.tags)

    def test_rejects_empty_tags(self) -> None:
        with self.assertRaisesRegex(ValueError, "at least one product tag"):
            rhoai_image_tags.load_mapping(write_mapping("tags:\n"))


class RhaivTagTests(unittest.TestCase):
    def test_parses_version_and_n(self) -> None:
        self.assertEqual(
            rhoai_image_tags.parse_rhaiv_tag("v0.1.5-rhaiv.4"),
            ("v0.1.5", 4),
        )

    def test_rejects_prerelease_and_plain_semver(self) -> None:
        with self.assertRaises(ValueError):
            rhoai_image_tags.parse_rhaiv_tag("v0.1.5")
        with self.assertRaises(ValueError):
            rhoai_image_tags.parse_rhaiv_tag("v0.1.5-pre.1")
        with self.assertRaises(ValueError):
            rhoai_image_tags.parse_rhaiv_tag("v0.1.5-rhaiv.01")

    def test_latest_rhaiv_uses_integer_n(self) -> None:
        latest = rhoai_image_tags.latest_rhaiv_for_version(
            (
                "v0.1.5-rhaiv.9",
                "v0.1.5-rhaiv.10",
                "v0.1.6-rhaiv.0",
                "v0.1.5-rhaiv.2",
            ),
            "v0.1.5",
        )
        self.assertEqual(latest, "v0.1.5-rhaiv.10")

    def test_latest_rhaiv_missing_version(self) -> None:
        self.assertIsNone(
            rhoai_image_tags.latest_rhaiv_for_version(("v0.1.5-rhaiv.1",), "v0.1.6")
        )


class PlanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = rhoai_image_tags.load_mapping(write_mapping(VALID_MAPPING))

    def test_plan_tracks_latest_rhaiv_per_mapped_version(self) -> None:
        planned, skipped = rhoai_image_tags.plan_branches(
            self.config,
            (
                "v0.1.5-rhaiv.3",
                "v0.1.5-rhaiv.4",
                "v0.1.6-rhaiv.0",
            ),
        )
        self.assertEqual(
            planned,
            (
                rhoai_image_tags.BranchPlan(
                    "rhoai-3.7-ea.1-e2e", "v0.1.5", "v0.1.5-rhaiv.4"
                ),
                rhoai_image_tags.BranchPlan(
                    "rhoai-3.7-ea.2-e2e", "v0.1.5", "v0.1.5-rhaiv.4"
                ),
                rhoai_image_tags.BranchPlan(
                    "rhoai-3.7-e2e", "v0.1.6", "v0.1.6-rhaiv.0"
                ),
            ),
        )
        self.assertEqual(skipped, (("rhoai-3.6-e2e", "v0.1.3"),))

    def test_from_rhaiv_only_moves_streams_for_that_openshell_version(self) -> None:
        planned, skipped = rhoai_image_tags.plan_branches(
            self.config,
            ("v0.1.5-rhaiv.4", "v0.1.6-rhaiv.0"),
            from_rhaiv="v0.1.5-rhaiv.4",
        )
        self.assertEqual(
            {item.branch for item in planned},
            {"rhoai-3.7-ea.1-e2e", "rhoai-3.7-ea.2-e2e"},
        )
        self.assertEqual({item.rhaiv_tag for item in planned}, {"v0.1.5-rhaiv.4"})
        self.assertEqual(skipped, ())

    def test_ea_streams_stay_on_last_v015_after_v016_exists(self) -> None:
        planned, _skipped = rhoai_image_tags.plan_branches(
            self.config,
            ("v0.1.5-rhaiv.4", "v0.1.6-rhaiv.1"),
        )
        by_branch = {item.branch: item.rhaiv_tag for item in planned}
        self.assertEqual(by_branch["rhoai-3.7-ea.1-e2e"], "v0.1.5-rhaiv.4")
        self.assertEqual(by_branch["rhoai-3.7-e2e"], "v0.1.6-rhaiv.1")


class ApplyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.src = init_repo()
        self.remote = Path(tempfile.mkdtemp()) / "remote.git"
        subprocess.run(
            ["git", "init", "--bare", "-b", "main", str(self.remote)],
            check=True,
            capture_output=True,
            text=True,
        )
        git(["remote", "add", "origin", str(self.remote)], cwd=self.src)
        git(["push", "-u", "origin", "HEAD:main"], cwd=self.src)
        git(["tag", "v0.1.5-rhaiv.1"], cwd=self.src)
        git(["push", "origin", "v0.1.5-rhaiv.1"], cwd=self.src)
        self.rhaiv_sha = git(["rev-parse", "HEAD"], cwd=self.src).stdout.strip()
        pipelinerun = self.src / ".tekton" / "odh-openshell-e2e-rhoai.yaml"
        pipelinerun.parent.mkdir(parents=True)
        pipelinerun.write_text(PIPELINERUN, encoding="utf-8")
        self.config = rhoai_image_tags.load_mapping(
            write_mapping(
                "tags:\n  rhoai-3.7-ea.1-e2e: v0.1.5\n  rhoai-3.7-e2e: v0.1.6\n"
            )
        )

    def test_apply_creates_branch_and_overlays_pipelinerun(self) -> None:
        planned, skipped = rhoai_image_tags.plan_branches(
            self.config, ("v0.1.5-rhaiv.1",)
        )
        rhoai_image_tags.apply_branches(
            self.src,
            planned,
            skipped,
            dry_run=False,
            remote="origin",
            pipelinerun=self.src / ".tekton" / "odh-openshell-e2e-rhoai.yaml",
        )
        branch_sha = git(
            ["rev-parse", "refs/heads/rhoai-3.7-ea.1-e2e"], cwd=self.remote
        ).stdout.strip()
        self.assertNotEqual(branch_sha, self.rhaiv_sha)
        self.assertEqual(
            git(["rev-parse", f"{branch_sha}^"], cwd=self.src).stdout.strip(),
            self.rhaiv_sha,
        )
        content = git(
            ["show", f"{branch_sha}:.tekton/odh-openshell-e2e-rhoai.yaml"],
            cwd=self.src,
        ).stdout
        self.assertEqual(content, PIPELINERUN)
        self.assertEqual(skipped, (("rhoai-3.7-e2e", "v0.1.6"),))

    def test_apply_is_idempotent(self) -> None:
        planned, skipped = rhoai_image_tags.plan_branches(
            self.config, ("v0.1.5-rhaiv.1",)
        )
        pipelinerun = self.src / ".tekton" / "odh-openshell-e2e-rhoai.yaml"
        rhoai_image_tags.apply_branches(
            self.src,
            planned,
            skipped,
            dry_run=False,
            remote="origin",
            pipelinerun=pipelinerun,
        )
        first = git(
            ["rev-parse", "refs/heads/rhoai-3.7-ea.1-e2e"], cwd=self.remote
        ).stdout.strip()
        rhoai_image_tags.apply_branches(
            self.src,
            planned,
            skipped,
            dry_run=False,
            remote="origin",
            pipelinerun=pipelinerun,
        )
        second = git(
            ["rev-parse", "refs/heads/rhoai-3.7-ea.1-e2e"], cwd=self.remote
        ).stdout.strip()
        self.assertEqual(first, second)

    def test_apply_without_overlay_pushes_rhaiv_commit(self) -> None:
        planned, skipped = rhoai_image_tags.plan_branches(
            self.config, ("v0.1.5-rhaiv.1",)
        )
        rhoai_image_tags.apply_branches(
            self.src,
            planned,
            skipped,
            dry_run=False,
            remote="origin",
            pipelinerun=None,
        )
        branch_sha = git(
            ["rev-parse", "refs/heads/rhoai-3.7-ea.1-e2e"], cwd=self.remote
        ).stdout.strip()
        self.assertEqual(branch_sha, self.rhaiv_sha)


if __name__ == "__main__":
    unittest.main()
