# PR #112 review follow-ups

## Task 1: Bound generic-fetcher retry delays

**Description:** Cap numeric HTTP `Retry-After` delays at 60 seconds while
preserving all existing retry classifications and exponential fallback logic.

**Acceptance criteria:**
- [x] `Retry-After: 7` still sleeps for 7 seconds.
- [x] A numeric value greater than 60 sleeps for 60 seconds.
- [x] Missing or non-numeric values retain exponential backoff.

**Verification:**
- [x] `mise run test:odh-generic-fetcher`

**Dependencies:** None

**Files likely touched:**
- `deploy/konflux/e2e-odh/sync-generic-fetcher.py`
- `deploy/konflux/e2e-odh/sync-generic-fetcher_test.py`

**Estimated scope:** Small

## Task 2: Align generic-fetcher task and CI

**Description:** Use `uv` + `pytest` for the downstream task and the ODH
contract workflow without adding a full `mise` bootstrap to that workflow.

**Acceptance criteria:**
- [x] The task uses the agreed `uv run --no-project --with pytest pytest` command.
- [x] CI keeps Python 3.12, installs pinned `uv`, and executes the equivalent command.
- [x] The offline synchronizer check remains in CI.

**Verification:**
- [x] `mise run test:odh-generic-fetcher`
- [x] Inspect workflow command and existing `paths` coverage.

**Dependencies:** Task 1

**Files likely touched:**
- `tasks/test-odh.toml`
- `.github/workflows/odh-deploy-contract.yml`

**Estimated scope:** Small

## Task 3: Validate and prepare local delivery

**Description:** Validate the complete scoped change, run the required security
scan, and create the single local downstream commit.

**Acceptance criteria:**
- [x] Focused tests, offline check, lint, format, and diff check pass.
- [ ] Strix could not run: `usestrix/strix:latest` is unavailable from the registry.
- [x] The commit is signed, starts with `CARRY:`, and is the sole commit over `origin/main`.

**Verification:**
- [x] `mise run test:odh-generic-fetcher`
- [x] `python3 deploy/konflux/e2e-odh/sync-generic-fetcher.py --check`
- [x] `mise run python:lint`
- [x] `mise run python:format:check`
- [x] `git diff --check`
- [ ] `docker run --rm -v $(pwd):/app usestrix/strix scan /app` (image unavailable)

**Dependencies:** Tasks 1-2

**Files likely touched:**
- No source changes expected

**Estimated scope:** Small

## Checkpoint: Ready for publication approval

- [ ] All task acceptance criteria are met.
- [ ] The final local diff and validation evidence are reviewed with the user.
- [ ] No branch is pushed and no pull request or external comment is created.
