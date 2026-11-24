#!/usr/bin/env bash

# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

# shellcheck source=/dev/null
if [[ -r /etc/profile.d/openclaw.sh ]]; then
  . /etc/profile.d/openclaw.sh
fi

if [[ -n "${OPENCLAW_PROFILE:-}" ]]; then
  echo "openclaw-start: OPENCLAW_PROFILE is not supported" >&2
  exit 2
fi

state_dir="${OPENCLAW_STATE_DIR:-${OPENCLAW_HOME:-$HOME}/.openclaw}"
config="${OPENCLAW_CONFIG_PATH:-${state_dir}/openclaw.json}"

# The Kubernetes driver sets the pod fsGroup, so kubelet makes the workspace
# volume setgid and every directory created under it inherits the bit.
# OpenClaw requires its private directories to be exactly 0700 and rejects
# 2700. Create its state directories without setgid so new subdirectories
# don't inherit it, and repair directories left by earlier runs.
prepare_state_dirs() {
  local dir
  for dir in "${state_dir}" "${HOME}/.openclaw-worker"; do
    # shellcheck disable=SC2174 # only the state directory itself must be private
    mkdir -p -m 0700 "${dir}"
    # Best effort: the agent workspace lives under the state directory, so
    # an unreadable or vanishing directory there must not block startup.
    if ! find "${dir}" -xdev -ignore_readdir_race -type d -perm -2000 -user "$(id -u)" -exec chmod g-s {} +; then
      echo "openclaw-start: warning: could not clear setgid everywhere under ${dir}" >&2
    fi
    # mkdir -m does not touch an existing directory's mode.
    chmod 0700 "${dir}"
  done
}

if [[ ! -e "${config}" ]]; then
  for name in MODEL_CONTEXT_WINDOW MODEL_MAX_TOKENS; do
    if [[ -n "${!name:-}" && ! "${!name}" =~ ^[1-9][0-9]*$ ]]; then
      echo "openclaw-start: ${name} must be a positive integer, got '${!name}'" >&2
      exit 2
    fi
  done
  if [[ -n "${MODEL_REASONING:-}" && "${MODEL_REASONING}" != "true" && "${MODEL_REASONING}" != "false" ]]; then
    echo "openclaw-start: MODEL_REASONING must be true or false, got '${MODEL_REASONING}'" >&2
    exit 2
  fi

  missing=()
  if [[ -z "${MODEL_BASE_URL:-}" ]]; then
    missing+=("MODEL_BASE_URL")
  fi
  if [[ -z "${MODEL_ID:-}" ]]; then
    missing+=("MODEL_ID")
  fi
  if [[ -z "${CUSTOM_API_KEY:-}" ]]; then
    missing+=("CUSTOM_API_KEY")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    names=""
    for name in "${missing[@]}"; do
      if [[ -z "${names}" ]]; then
        names="${name}"
      else
        names="${names}, ${name}"
      fi
    done
    echo "openclaw-start: no OpenClaw config at ${config}; set ${names} for first-run setup" >&2
    for name in "${missing[@]}"; do
      if [[ "${name}" == "CUSTOM_API_KEY" ]]; then
        echo "openclaw-start: attach an OpenShell provider of type openclaw-model (see model-provider-profile.yaml); it injects CUSTOM_API_KEY and allows /usr/bin/node to reach the model host:port. For an endpoint without auth, create it with --credential CUSTOM_API_KEY=unused" >&2
        break
      fi
    done
    exit 2
  fi

  prepare_state_dirs

  if ! out=$(openclaw onboard \
    --non-interactive \
    --accept-risk \
    --mode local \
    --auth-choice custom-api-key \
    --custom-base-url "$MODEL_BASE_URL" \
    --custom-model-id "$MODEL_ID" \
    --custom-compatibility openai \
    --custom-provider-id openshell-model \
    --custom-text-input \
    --secret-input-mode ref \
    --gateway-bind loopback \
    --gateway-auth token \
    --gateway-port 18789 \
    --skip-channels \
    --skip-daemon \
    --skip-health \
    --skip-search \
    --skip-skills \
    --skip-ui \
    --skip-hooks \
    --json 2>&1); then
    printf '%s\n' "${out}" >&2
    echo "openclaw-start: onboarding failed" >&2
    exit 1
  fi

  # Onboarding writes a single model entry with maxTokens 4096 and reasoning
  # off. A reasoning model can spend that whole allowance thinking and return
  # no answer, so let the environment override those defaults.
  model_path="models.providers.openshell-model.models[0]"
  for pair in contextWindow:MODEL_CONTEXT_WINDOW maxTokens:MODEL_MAX_TOKENS reasoning:MODEL_REASONING; do
    key="${pair%%:*}"
    name="${pair#*:}"
    if [[ -n "${!name:-}" ]]; then
      if ! out=$(openclaw config set "${model_path}.${key}" "${!name}" --strict-json 2>&1); then
        printf '%s\n' "${out}" >&2
        echo "openclaw-start: failed to set ${key} from ${name}" >&2
        # Remove the half-configured onboarding so the next start retries it.
        rm -f "${config}" "${config}.bak"
        exit 1
      fi
    fi
  done

  echo "openclaw-start: wrote ${config} (provider openshell-model, model ${MODEL_ID})" >&2
else
  prepare_state_dirs
fi

if (($# == 0)); then
  set -- tui --local
fi

exec openclaw "$@"
