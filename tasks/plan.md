# Implementation Plan: PR #112 review follow-ups

## Overview

Address Emilien's two approved follow-ups from downstream PR #112: bound numeric
`Retry-After` handling in the generic-fetcher checksum updater, and run its
Python regression suite through the repository's `uv` + `pytest` convention.
The scope excludes deployment, image, checksum, and retry-policy changes other
than the delay ceiling.

## Architecture decisions

- Numeric `Retry-After` values are capped at 60 seconds. Missing or non-numeric
  values retain the existing exponential-backoff behavior.
- The local task and CI execute the same explicit `uv run ... pytest` command.
  The lean ODH workflow retains Python 3.12 and adds pinned `setup-uv`; it does
  not bootstrap the full `mise` toolchain solely to dispatch one test.
- The existing RHAIENG-7753 Notion analysis records the feedback, alternatives,
  decision, and test traceability.

## Dependency graph

```
retry delay rule ──> unit regression coverage ──> focused validation
uv/pytest task ────> CI setup and invocation ──> workflow validation
```

## Blast radius

- `_with_retry` is shared by artifact hashing and checksum-sidecar retrieval;
  only its numeric wait duration changes.
- `test:odh-generic-fetcher` has no task consumers; the ODH Deploy Contract
  workflow invokes the test file directly and must be aligned.
- Workflow path filters already cover the Python helper, test task, and
  workflow; no additional trigger paths are needed.

## Task list

1. Add the 60-second retry-delay ceiling and tests for ordinary, oversized, and
   invalid/absent `Retry-After` values.
2. Switch the ODH generic-fetcher task to the repository `uv` + `pytest`
   invocation and align its lightweight CI workflow with pinned `setup-uv`.
3. Run focused tests, offline consistency validation, Python lint/format,
   diff checks, and Strix; review the staged diff and commit as one signed
   `CARRY:` commit. Do not publish without explicit approval.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| A malformed header changes retry behavior | Explicit fallback regression coverage preserves exponential backoff. |
| CI and local task drift | Use the same `uv run` command and validate both surfaces. |
| Existing local changes leak into the PR | Stage only the four scoped source/config files and the plan artifacts. |
