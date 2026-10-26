#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Best-effort rendering must never replace the test suite's exit status.
e2e_render_html() {
  local xml=$1 title=$2 html=${3:-${1%.xml}.html}
  local stylesheet
  [[ -f "${xml}" ]] || return 0
  stylesheet="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/junit-to-html.xsl"
  if command -v xsltproc >/dev/null 2>&1; then
    xsltproc --stringparam title "${title}" "${stylesheet}" "${xml}" >"${html}" \
      && echo "HTML report: ${html}" \
      || echo "WARNING: failed to render HTML report from ${xml}" >&2
  else
    echo "WARNING: xsltproc not found; keeping JUnit report ${xml}" >&2
  fi
  return 0
}
