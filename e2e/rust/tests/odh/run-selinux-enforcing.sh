#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Run one downstream OCP scenario and reject SELinux AVCs emitted by the
# OpenShell supervisor while it ran. OCP audit logs live on the node, not in
# the sandbox pod, so this uses `oc debug node`.
#
# Usage: run-selinux-enforcing.sh <scenario-name> <command> [args...]

set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 2; }

# Kubernetes side-loads the combined/process supervisor at the first path.
# Its init container and sidecar network supervisor run directly from the
# supervisor image at the second path. Use `ausearch -x` rather than `-c`:
# Linux truncates the 17-character process comm "openshell-sandbox" to
# TASK_COMM_LEN, making a comm filter silently miss it.
SUPERVISOR_EXES=(
  "/opt/openshell/bin/openshell-sandbox"
  "/openshell-sandbox"
)
# The downstream gateway image runs from this stable Konflux image path. The
# ticket requires OpenShell-related AVCs, not only supervisor AVCs.
OPENSHELL_EXES=(
  "${SUPERVISOR_EXES[@]}"
  "/usr/local/bin/openshell-gateway"
)

[ "$#" -ge 1 ] || fail "usage: $0 [--preflight | <scenario-name> <command> [args...]]"
command -v oc >/dev/null 2>&1 || fail "oc is required"

oc_args=()
if [ -n "${OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE:-}" ]; then
  oc_args=(--context "${OPENSHELL_E2E_KUBE_CONTEXT_ACTIVE}")
fi

# All commands are captured; they must never attach stdin or allocate a PTY.
# Apart from avoiding needless interactive plumbing for one-shot commands,
# this prevents oc from disturbing the terminal mode inherited by Cargo.
debug_node() {
  oc "${oc_args[@]}" debug "node/$1" --quiet --no-stdin --no-tty -- \
    chroot /host "${@:2}"
}

require_enforcing() {
  local node="$1" enforcing
  enforcing="$(debug_node "${node}" getenforce 2>&1)" \
    || fail "unable to determine SELinux mode on node/${node}: ${enforcing:-unknown}"
  [ "${enforcing}" = "Enforcing" ] \
    || fail "node/${node} SELinux mode is ${enforcing:-unknown}; expected Enforcing"
}

nodes=()
while IFS= read -r node; do
  [ -n "$node" ] && nodes+=("$node")
done < <(oc "${oc_args[@]}" get nodes -l node-role.kubernetes.io/worker \
  --no-headers \
  -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
  | awk '$2 == "True" { print $1 }')
if [ "${#nodes[@]}" -eq 0 ]; then
  # Single-node clusters and bespoke OCP installations may omit the worker
  # role label. Keep the lane usable there, but make the broader scope clear.
  echo "WARNING: no worker-labeled nodes found; auditing all Ready nodes." >&2
  while IFS= read -r node; do
    [ -n "$node" ] && nodes+=("$node")
  done < <(oc "${oc_args[@]}" get nodes --no-headers \
    -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
    | awk '$2 == "True" { print $1 }')
fi
[ "${#nodes[@]}" -gt 0 ] || fail "no eligible OpenShift nodes were returned"

if [ "${1:-}" = "--preflight" ]; then
  for node in "${nodes[@]}"; do
    require_enforcing "${node}"
  done
  exit 0
fi

[ "$#" -ge 2 ] || fail "usage: $0 <scenario-name> <command> [args...]"
scenario="$1"
shift

# `ausearch -ts` uses the audited node's local clock. Record each cutoff on
# that node after proving SELinux enforcing, instead of assuming the test
# machine and every worker have the same timezone.
audit_start_dates=()
audit_start_times=()
for node in "${nodes[@]}"; do
  if [ "${ODH_SELINUX_ENFORCING_VERIFIED:-0}" != "1" ]; then
    require_enforcing "${node}"
  fi

  # Keep the timestamp's locale identical to ausearch's parser. RHCOS uses
  # the C locale's two-digit year (%x), while a hard-coded four-digit date is
  # rejected by its audit userspace.
  cutoff="$(debug_node "${node}" env LC_ALL=C date '+%x %X' 2>&1)" \
    || fail "unable to record AVC cutoff on node/${node}: ${cutoff:-unknown}"
  audit_start_dates+=("${cutoff%% *}")
  audit_start_times+=("${cutoff##* }")
done

set +e
"$@"
scenario_status=$?
set -e

audit_failed=0
for index in "${!nodes[@]}"; do
  node="${nodes[$index]}"
  set +e
  # Query every OpenShell executable in one debug pod. ausearch uses exit 1
  # for no matches, so normalize only that documented result; all query errors
  # remain failures.
  audit_output="$(debug_node "${node}" sh -c '
    start_date="$1"; start_time="$2"; shift 2
    for executable in "$@"; do
      output="$(LC_ALL=C ausearch -m AVC -ts "$start_date" "$start_time" -x "$executable" -i 2>&1)"
      status=$?
      if [ "$status" -eq 1 ] && [ "$output" = "<no matches>" ]; then
        continue
      fi
      if [ "$status" -ne 0 ]; then
        echo "QUERY ERROR for $executable: $output"
        exit "$status"
      fi
      if [ -n "$output" ]; then
        echo "AVCs for $executable:"
        echo "$output"
      fi
    done
  ' -- "${audit_start_dates[$index]}" "${audit_start_times[$index]}" "${OPENSHELL_EXES[@]}" 2>&1)"
  audit_status=$?
  set -e

  if [ "$audit_status" -ne 0 ]; then
    echo "ERROR: ${scenario}: unable to query OpenShell AVCs on node/${node}:" >&2
    echo "$audit_output" >&2
    audit_failed=1
  elif [ -n "$audit_output" ]; then
    echo "ERROR: ${scenario}: OpenShell AVCs on node/${node}:" >&2
    echo "$audit_output" >&2
    audit_failed=1
  fi
done

if [ "$scenario_status" -ne 0 ]; then
  echo "ERROR: ${scenario}: scenario failed with exit code ${scenario_status}" >&2
fi

[ "$scenario_status" -eq 0 ] && [ "$audit_failed" -eq 0 ]
