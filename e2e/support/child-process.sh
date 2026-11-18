#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

E2E_CHILD_PID=""
E2E_CHILD_STARTING=0
E2E_CHILD_CANCEL=""
E2E_CHILD_SUPPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

e2e_stop_child() {
  local code=$1
  # Defer cancellation until the asynchronous launch has published its PID.
  if [[ "${E2E_CHILD_STARTING}" == 1 ]]; then
    E2E_CHILD_CANCEL=$code
    return
  fi
  trap '' INT TERM
  if [[ -n "${E2E_CHILD_PID}" ]]; then
    kill -TERM "${E2E_CHILD_PID}" 2>/dev/null || true
    # The supervisor bounds this wait and escalates to KILL for the child group.
    wait "${E2E_CHILD_PID}" || true
  fi
  exit "${code}"
}

e2e_run_child() {
  local status=0
  E2E_CHILD_STARTING=1
  "${PYTHON_BIN:-python3}" "${E2E_CHILD_SUPPORT_DIR}/run-child.py" \
    --grace "${E2E_CHILD_GRACE_SECONDS:-10}" -- "$@" <&0 &
  E2E_CHILD_PID=$!
  E2E_CHILD_STARTING=0
  if [[ -n "${E2E_CHILD_CANCEL}" ]]; then e2e_stop_child "${E2E_CHILD_CANCEL}"; fi
  wait "${E2E_CHILD_PID}" || status=$?
  E2E_CHILD_PID=""
  return "${status}"
}
