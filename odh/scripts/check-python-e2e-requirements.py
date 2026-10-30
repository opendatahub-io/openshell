#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Verify odh/requirements.in mirrors the root dev group's pytest plugins.

The Konflux e2e image installs odh/requirements.txt (compiled from
requirements.in) with no network at test time, so a pytest plugin that
exists in the dev environment but not in the image surfaces only as an
import error during collection inside the image. This check compares the
pytest-* entries of both files — names and version constraints — so the
drift fails locally instead.
"""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

from packaging.requirements import InvalidRequirement, Requirement
from packaging.version import InvalidVersion, Version

ROOT = Path(__file__).resolve().parents[2]


def normalize_name(name: str) -> str:
    """Return a distribution name in its PEP 503 canonical form."""
    return re.sub(r"[-_.]+", "-", name).lower()


# pytest plugins deliberately absent from the e2e image, each with the
# reason the exclusion is intentional. Keys use the same canonical form as
# parsed requirements so alternate valid spellings do not create false drift.
ALLOWED_MISSING: dict[str, str] = {
    normalize_name("pytest-cov"): "coverage is not collected in the e2e image",
}


def parse_pytest_requirement(raw: str, source: str) -> tuple[str, Requirement] | None:
    """Parse a pytest PEP 508 requirement and return its canonical name."""
    raw = raw.removesuffix("\\").strip()
    try:
        requirement = Requirement(raw)
    except InvalidRequirement as error:
        if raw.lower().startswith("pytest"):
            raise SystemExit(
                f"{source}: invalid pytest requirement {raw!r}: {error}"
            ) from error
        return None

    name = normalize_name(requirement.name)
    if not name.startswith("pytest"):
        return None
    return name, requirement


def add_plugin(
    plugins: dict[str, Requirement], plugin: tuple[str, Requirement], source: str
) -> None:
    name, requirement = plugin
    if name in plugins:
        raise SystemExit(
            f"{source}: pytest requirement {name!r} is declared more than once"
        )
    plugins[name] = requirement


def dev_pytest_plugins(root: Path) -> dict[str, Requirement]:
    with (root / "pyproject.toml").open("rb") as stream:
        pyproject = tomllib.load(stream)
    dev = pyproject.get("dependency-groups", {}).get("dev", [])
    if not isinstance(dev, list):
        raise SystemExit("pyproject.toml: [dependency-groups].dev must be an array")
    plugins: dict[str, Requirement] = {}
    for requirement in dev:
        if not isinstance(requirement, str):
            continue
        plugin = parse_pytest_requirement(
            requirement, "pyproject.toml dependency-groups.dev"
        )
        if plugin is not None:
            add_plugin(plugins, plugin, "pyproject.toml dependency-groups.dev")
    return plugins


def pytest_plugins_from_file(path: Path) -> dict[str, Requirement]:
    plugins: dict[str, Requirement] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        plugin = parse_pytest_requirement(line, str(path))
        if plugin is not None:
            add_plugin(plugins, plugin, str(path))
    return plugins


def image_pytest_plugins(root: Path) -> dict[str, Requirement]:
    return pytest_plugins_from_file(root / "odh" / "requirements.in")


def compiled_image_pytest_plugins(root: Path) -> dict[str, Requirement]:
    return pytest_plugins_from_file(root / "odh" / "requirements.txt")


def locked_version(requirement: Requirement) -> Version | None:
    """Extract the single concrete version from a compiled requirement."""
    versions = [
        specifier.version
        for specifier in requirement.specifier
        if specifier.operator in {"==", "==="} and "*" not in specifier.version
    ]
    if len(versions) != 1:
        return None
    try:
        return Version(versions[0])
    except InvalidVersion:
        return None


def compiled_requirement_satisfies(
    required: Requirement, compiled: Requirement
) -> bool:
    """Return whether the locked package can satisfy the image requirement."""
    if required.url is not None:
        return compiled.url == required.url
    if compiled.url is not None:
        return False
    version = locked_version(compiled)
    return version is not None and version in required.specifier


def main(argv: list[str]) -> int:
    root = Path(argv[1]).resolve() if len(argv) > 1 else ROOT
    dev = dev_pytest_plugins(root)
    image = image_pytest_plugins(root)
    compiled = compiled_image_pytest_plugins(root)
    errors: list[str] = []
    for name, requirement in dev.items():
        if name in ALLOWED_MISSING:
            continue
        if name not in image:
            errors.append(
                f"{name} ({requirement.specifier or 'unpinned'}) is in the dev group"
                " but not in odh/requirements.in"
            )
        elif image[name] != requirement:
            errors.append(
                f"{name}: dev group requires {requirement},"
                f" odh/requirements.in requires {image[name]}"
            )
        if name not in compiled:
            errors.append(
                f"{name} is required by odh/requirements.in but absent from"
                " compiled odh/requirements.txt"
            )
        elif not compiled_requirement_satisfies(requirement, compiled[name]):
            errors.append(
                f"{name}: compiled odh/requirements.txt has {compiled[name]},"
                f" which does not satisfy odh/requirements.in {requirement}"
            )
    for name in image:
        if name not in dev:
            errors.append(f"{name} is in odh/requirements.in but not in the dev group")
    if errors:
        print(
            "ERROR: pytest plugin drift between pyproject.toml [dependency-groups].dev"
            " and odh/requirements.in:",
            file=sys.stderr,
        )
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        print(
            "Mirror the change in odh/requirements.in (and recompile requirements.txt)"
            " or extend ALLOWED_MISSING with a reason.",
            file=sys.stderr,
        )
        return 1
    print(
        f"ok: {len(image)} pytest plugin(s) mirrored"
        " between the dev group and odh/requirements.in"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
