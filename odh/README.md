# Manually sync NVIDIA OpenShell into opendatahub-io

There is automation to auto-sync upstream commits to downstream, but in case of conflicts, the sync will fail and you will need to manually sync and resolve the conflicts by following this guide.

Merge `NVIDIA/OpenShell` `main` into `opendatahub-io/openshell` `main`. Use merge, not rebase.

## Fetch remotes

Clone your fork of `opendatahub-io/openshell`. That remote is `origin`, which you push to for the PR. Add NVIDIA as `upstream` and the ODH repo as `odh` if they are missing.

```shell
git clone git@github.com:<you>/OpenShell.git
cd OpenShell
git remote add upstream git@github.com:NVIDIA/OpenShell.git
git remote add odh git@github.com:opendatahub-io/openshell.git
git fetch upstream
git fetch odh
```

## Branch from odh/main

Start from current ODH `main`. Do not replay NVIDIA commits onto the branch first.

```shell
git checkout -b <any-branch-name> odh/main
git merge upstream/main
```

## Resolve conflicts

Keep both sides. NVIDIA owns product behavior. ODH commits own Konflux, UBI and RPM lockfiles, OpenShift e2e, `odh/`, and other fork-only files.

- Open every unmerged path.
- Keep upstream changes. Keep ODH carry patches in the same file when both apply.
- Agents can propose a resolution. Review each file before you stage it.

Stage resolved files, then finish the merge.

## Open a PR

Push the branch and open a pull request against `opendatahub-io/openshell` `main`. Wait for CI and Konflux checks to pass. Merge the PR with **Create a merge commit**. Do not use Rebase and merge or Squash and merge.

```shell
git push -u origin HEAD
```
