#!/usr/bin/env python3
"""Validated, data-only resolver for downstream ODH gateway phases."""

from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path

PLAN_FILE = Path(__file__).with_name("tiers.toml")
REPO_ROOT = PLAN_FILE.parents[4]
GLOBAL_EXCLUSIONS_KEY = "global_test_exclusions"
_BINARY = re.compile(r"[A-Za-z0-9_-]+\Z")
_FILTER = re.compile(r"[A-Za-z0-9_:]+\Z")


def _validate_mode(mode_name: str, mode: dict) -> dict:
    if not isinstance(mode, dict):
        raise ValueError(f"mode {mode_name!r} must be a table")
    expected = mode.get("expected_helm_values")
    if not isinstance(expected, dict):
        raise ValueError(f"mode {mode_name!r} expected_helm_values must be a table")
    overlays = mode.get("helm_values", [])
    if not isinstance(overlays, list):
        raise ValueError(f"mode {mode_name!r} helm_values must be an array")
    for overlay in overlays:
        if not isinstance(overlay, str):
            raise ValueError(f"mode {mode_name!r} overlay path must be a string")
        candidate = (REPO_ROOT / overlay).resolve()
        if Path(overlay).is_absolute() or not candidate.is_relative_to(REPO_ROOT) or not candidate.is_file():
            raise ValueError(f"unsafe or missing Helm overlay path: {overlay!r}")
    return {**mode, "helm_values": overlays}


def load_plan(tier: str, plan_path: Path = PLAN_FILE) -> dict:
    """Load and validate a tier, including all phase and mode references."""
    plan_path = Path(plan_path).resolve()
    with plan_path.open("rb") as stream:
        raw = tomllib.load(stream)
    modes = raw.get("modes", {})
    global_exclusions = raw.get(GLOBAL_EXCLUSIONS_KEY, {})
    tiers = {
        key: value
        for key, value in raw.items()
        if key not in {"modes", GLOBAL_EXCLUSIONS_KEY}
    }
    if not isinstance(modes, dict) or not isinstance(tiers, dict):
        raise ValueError("tier plan must define mode and tier tables")
    if not isinstance(global_exclusions, dict) or any(
        not isinstance(binary, str) or not _BINARY.fullmatch(binary)
        for binary in global_exclusions
    ):
        raise ValueError("global_test_exclusions must map valid binary names to test arrays")
    for tests in global_exclusions.values():
        if not isinstance(tests, list) or any(
            not isinstance(test, str) or not _FILTER.fullmatch(test)
            for test in tests
        ):
            raise ValueError("global_test_exclusions must map valid binary names to test arrays")
    for mode_name, mode in modes.items():
        _validate_mode(mode_name, mode)
    if tier not in tiers:
        raise ValueError(f"unknown tier {tier!r}; available: {', '.join(sorted(tiers))}")
    entry = tiers[tier]
    if not isinstance(entry, dict):
        raise ValueError(f"tier {tier!r} must be a table")
    base_mode = entry.get("mode", "shared")
    phase_tables = [(base_mode, entry)]
    phase_tables.extend(
        (name, config)
        for name, config in entry.items()
        if name in modes and name != base_mode
    )
    names: set[str] = set()
    resolved = []
    for phase_name, phase_config in phase_tables:
        phase = phase_config
        if not isinstance(phase, dict):
            raise ValueError(f"phase {phase_name!r} in tier {tier!r} must be a table")
        name, mode_name = phase_name, phase.get("mode", phase_name)
        if not isinstance(name, str) or not _BINARY.fullmatch(name) or name in names:
            raise ValueError(f"invalid or duplicate phase name: {name!r}")
        names.add(name)
        if not isinstance(mode_name, str) or mode_name not in modes:
            raise ValueError(f"unknown mode {mode_name!r} in tier {tier!r}")
        binaries = phase.get("upstream_tests", [])
        exclusions = phase.get("upstream_test_exclusions", {})
        excluded_binaries = phase.get("excluded_binaries", [])
        if not isinstance(excluded_binaries, list) or any(not isinstance(b, str) or not _BINARY.fullmatch(b) for b in excluded_binaries):
            raise ValueError(f"invalid excluded binary in phase {name!r}")
        if excluded_binaries and not phase.get("all_binaries"):
            raise ValueError(f"phase {name!r} may exclude binaries only when selecting all binaries")
        if not isinstance(binaries, list) or any(not isinstance(b, str) or not _BINARY.fullmatch(b) for b in binaries):
            raise ValueError(f"invalid upstream test binary in phase {name!r}")
        if not isinstance(exclusions, dict) or any(not isinstance(binary, str) or not _BINARY.fullmatch(binary) for binary in exclusions):
            raise ValueError(f"invalid excluded test binary in phase {name!r}")
        if not phase.get("all_binaries") and set(exclusions) - set(binaries):
            raise ValueError(f"exclusions reference unselected binaries in phase {name!r}")
        for tests in exclusions.values():
            if not isinstance(tests, list) or any(not isinstance(t, str) or not _FILTER.fullmatch(t) for t in tests):
                raise ValueError(f"invalid upstream test exclusion in phase {name!r}")
        odh_filter = phase.get("odh_filter", "")
        if not isinstance(odh_filter, str) or (odh_filter and not _FILTER.fullmatch(odh_filter)):
            raise ValueError(f"invalid ODH test filter in phase {name!r}")
        for flag in ("all_binaries", "all_odh_tests", "include_image_provenance"):
            if flag in phase and not isinstance(phase[flag], bool):
                raise ValueError(f"phase {name!r} {flag} must be a boolean")
        if not binaries and not odh_filter and not phase.get("all_binaries") and not phase.get("all_odh_tests") and not phase.get("odh_only") and not phase.get("include_image_provenance"):
            raise ValueError(f"phase {name!r} selects no tests")
        if "odh_only" in phase and not isinstance(phase["odh_only"], bool):
            raise ValueError(f"phase {name!r} odh_only must be a boolean")
        resolved.append({**phase, "name": name, "mode": mode_name, "upstream_tests": binaries,
                         "upstream_test_exclusions": exclusions, "odh_filter": odh_filter,
                         "global_test_exclusions": global_exclusions,
                         "all_odh_tests": phase.get("all_odh_tests", phase.get("odh_only", False)),
                         "include_image_provenance": phase.get("include_image_provenance", mode_name == "shared")})
    return {"tier": tier, "phases": resolved, "modes": modes}


def resolve_phase(plan: dict, phase_name: str) -> dict:
    for phase in plan["phases"]:
        if phase["name"] == phase_name:
            return phase
    raise ValueError(f"unknown phase {phase_name!r} for tier {plan['tier']!r}")


def load_mode(mode_name: str, plan_path: Path = PLAN_FILE) -> dict:
    """Resolve a validated named mode for the deployment helper."""
    with Path(plan_path).open("rb") as stream:
        raw = tomllib.load(stream)
    modes = raw.get("modes", {})
    if not isinstance(modes, dict):
        raise ValueError("tier plan must define a modes table")
    if mode_name not in modes:
        raise ValueError(f"unknown mode {mode_name!r}; available: {', '.join(sorted(modes))}")
    return _validate_mode(mode_name, modes[mode_name])


def nextest_filter(phase: dict) -> str:
    terms = []
    odh_filter = phase["odh_filter"]
    if odh_filter:
        terms.append(f"(binary(=odh) & test(~{odh_filter}))")
    elif phase.get("all_odh_tests"):
        terms.append("binary(=odh)")
    if phase.get("all_binaries"):
        exclusions = phase.get("upstream_test_exclusions", {})
        excluded = " | ".join([*(f"binary(={binary})" for binary in phase.get("excluded_binaries", [])),
                                *(f"(binary(={binary}) & test(={test}))" for binary, tests in exclusions.items() for test in tests)])
        terms.append(f"(all() - ({excluded}))" if excluded else "all()")
    else:
        for binary in phase["upstream_tests"]:
            selection = f"binary(={binary})"
            for test in phase["upstream_test_exclusions"].get(binary, []):
                selection = f"({selection} - test(={test}))"
            terms.append(selection)
    provenance = "smoke::image_provenance::"
    covered = bool(odh_filter) and provenance.startswith(odh_filter)
    if phase.get("include_image_provenance") and not phase.get("all_binaries") and not phase.get("all_odh_tests") and not covered:
        terms.append(f"(binary(=odh) & test(~{provenance}))")
    if not terms:
        raise ValueError(f"phase {phase['name']!r} selects no tests")
    selection = " | ".join(terms)
    global_exclusions = phase.get("global_test_exclusions", {})
    excluded = " | ".join(
        f"(binary(={binary}) & test(={test}))"
        for binary, tests in global_exclusions.items()
        for test in tests
    )
    return f"({selection}) - ({excluded})" if excluded else selection


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--mode":
            print(json.dumps(load_mode(sys.argv[2], Path(sys.argv[3]) if len(sys.argv) > 3 else PLAN_FILE)))
            raise SystemExit(0)
        plan = load_plan(sys.argv[1], Path(sys.argv[2]) if len(sys.argv) > 2 else PLAN_FILE)
        if len(sys.argv) > 3:
            phase = resolve_phase(plan, sys.argv[3])
            print(json.dumps({"phase": phase, "filter": nextest_filter(phase)}))
        else:
            print(json.dumps(plan))
    except (ValueError, OSError, tomllib.TOMLDecodeError) as exc:
        sys.exit(str(exc))
